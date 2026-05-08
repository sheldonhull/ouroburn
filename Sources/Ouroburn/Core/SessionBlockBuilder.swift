import Foundation

/// Splits an entry stream into 5-hour Claude billing blocks.
///
/// Mirrors ccusage `_session-blocks.ts:90-152`. Block start floors to UTC hour. A new block
/// opens when either the current entry exceeds the running 5h window relative to the block
/// start, or the gap since the last entry exceeds 5h. A gap block is emitted only when the
/// gap strictly exceeds 5h.
struct SessionBlockBuilder {
    static let blockDuration: TimeInterval = 5 * 60 * 60

    func build(entries: [UsageEntry], now: Date = Date()) -> [SessionBlock] {
        guard !entries.isEmpty else { return [] }
        let sorted = entries.sorted { $0.timestamp < $1.timestamp }
        var blocks: [SessionBlock] = []
        var bucket: Bucket?

        for entry in sorted {
            if var current = bucket {
                let sinceStart = entry.timestamp.timeIntervalSince(current.start)
                let sinceLast = entry.timestamp.timeIntervalSince(current.lastTimestamp)
                if sinceStart > Self.blockDuration || sinceLast > Self.blockDuration {
                    blocks.append(current.finalize(now: now))
                    if sinceLast > Self.blockDuration {
                        let gapStart = current.lastTimestamp.addingTimeInterval(Self.blockDuration)
                        blocks.append(SessionBlock(
                            id: "gap-" + ISO8601.format(gapStart),
                            start: gapStart,
                            end: entry.timestamp,
                            actualEnd: entry.timestamp,
                            entries: [],
                            isActive: false,
                            isGap: true
                        ))
                    }
                    bucket = Bucket(start: Self.floorToUTCHour(entry.timestamp), entry: entry)
                } else {
                    current.add(entry)
                    bucket = current
                }
            } else {
                bucket = Bucket(start: Self.floorToUTCHour(entry.timestamp), entry: entry)
            }
        }
        if let bucket {
            blocks.append(bucket.finalize(now: now))
        }
        return blocks
    }

    static func floorToUTCHour(_ date: Date) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let comps = calendar.dateComponents([.year, .month, .day, .hour], from: date)
        return calendar.date(from: comps) ?? date
    }
}

private struct Bucket {
    var start: Date
    var entries: [UsageEntry]
    var lastTimestamp: Date

    init(start: Date, entry: UsageEntry) {
        self.start = start
        entries = [entry]
        lastTimestamp = entry.timestamp
    }

    mutating func add(_ entry: UsageEntry) {
        entries.append(entry)
        lastTimestamp = entry.timestamp
    }

    func finalize(now: Date) -> SessionBlock {
        let end = start.addingTimeInterval(SessionBlockBuilder.blockDuration)
        let active = now.timeIntervalSince(lastTimestamp) < SessionBlockBuilder.blockDuration
            && now < end
        return SessionBlock(
            id: ISO8601.format(start),
            start: start,
            end: end,
            actualEnd: lastTimestamp,
            entries: entries,
            isActive: active,
            isGap: false
        )
    }
}

struct SessionBlock: Equatable, Sendable {
    let id: String
    let start: Date
    let end: Date
    let actualEnd: Date
    let entries: [UsageEntry]
    let isActive: Bool
    let isGap: Bool
}

extension ISO8601 {
    static func format(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: date)
    }
}

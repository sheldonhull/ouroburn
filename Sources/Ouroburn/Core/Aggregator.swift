import Foundation

/// Buckets a stream of UsageEntry into rows for any ViewMode.
///
/// Daily/weekly/monthly bucketing mirrors ccusage `_date-utils.ts:81-116` using the system local
/// timezone (no `--timezone` override yet). Session grouping uses the JSONL filesystem layout —
/// project + session id — per ccusage `data-loader.ts:961-989`. The 5-hour block view delegates
/// to `SessionBlockBuilder`.
struct Aggregator {
    let pricing: [String: ModelPricing]
    let calendar: Calendar
    let weekStart: Int

    init(
        pricing: [String: ModelPricing],
        calendar: Calendar = .current,
        weekStart: Int = 1
    ) {
        self.pricing = pricing
        self.calendar = calendar
        self.weekStart = weekStart
    }

    func aggregate(entries: [UsageEntry], mode: ViewMode, now: Date = Date()) -> [AggregateBucket] {
        switch mode {
        case .day: groupByDateString(entries) { Self.dayKey(for: $0, calendar: calendar) }
        case .week: groupByDateString(entries) { Self.weekKey(for: $0, calendar: calendar, weekStart: weekStart) }
        case .month: groupByDateString(entries) { Self.monthKey(for: $0, calendar: calendar) }
        case .session: groupBySession(entries)
        case .sessionBlock: groupByFiveHourBlock(entries, now: now)
        }
    }

    func cost(of entry: UsageEntry) -> Double {
        if let cost = entry.costUSD { return cost }
        return PricingResolver.resolve(model: entry.model, table: pricing)?.cost(for: entry) ?? 0
    }

    /// Time-axis samples for the line graph. Granularity scales with the view mode:
    /// hourly for day/sessionBlock, daily for week/month. Session mode skips the graph.
    func timeline(entries: [UsageEntry], mode: ViewMode, now: Date = Date()) -> [TimelinePoint] {
        switch mode {
        case .day:
            return hourlyTimeline(entries: entries, anchor: startOfDay(now), hours: 24)
        case .sessionBlock:
            return hourlyTimeline(entries: entries, anchor: now.addingTimeInterval(-12 * 3600), hours: 12)
        case .week:
            return dailyTimeline(entries: entries, anchor: startOfWeek(now), days: 7)
        case .month:
            let dayCount = daysInCurrentMonth(now)
            return dailyTimeline(entries: entries, anchor: startOfMonth(now), days: dayCount)
        case .session:
            // Session rows have no inherent time axis, so the graph summarises cost over the
            // trailing 7 days of activity feeding the session list.
            let anchor = calendar.date(byAdding: .day, value: -6, to: startOfDay(now)) ?? now
            return dailyTimeline(entries: entries, anchor: anchor, days: 7)
        }
    }

    private func hourlyTimeline(entries: [UsageEntry], anchor: Date, hours: Int) -> [TimelinePoint] {
        let bucketSize: TimeInterval = 3600
        var points: [TimelinePoint] = []
        points.reserveCapacity(hours)
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        for hourIndex in 0 ..< hours {
            let bucketStart = anchor.addingTimeInterval(Double(hourIndex) * bucketSize)
            let bucketEnd = bucketStart.addingTimeInterval(bucketSize)
            let slice = entries.filter { $0.timestamp >= bucketStart && $0.timestamp < bucketEnd }
            points.append(samplePoint(slice: slice, start: bucketStart, label: formatter.string(from: bucketStart)))
        }
        return points
    }

    private func dailyTimeline(entries: [UsageEntry], anchor: Date, days: Int) -> [TimelinePoint] {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d"
        var points: [TimelinePoint] = []
        points.reserveCapacity(days)
        for dayIndex in 0 ..< days {
            let bucketStart = calendar.date(byAdding: .day, value: dayIndex, to: anchor) ?? anchor
            let bucketEnd = calendar.date(byAdding: .day, value: 1, to: bucketStart) ?? bucketStart
            let slice = entries.filter { $0.timestamp >= bucketStart && $0.timestamp < bucketEnd }
            points.append(samplePoint(slice: slice, start: bucketStart, label: formatter.string(from: bucketStart)))
        }
        return points
    }

    private func samplePoint(slice: [UsageEntry], start: Date, label: String) -> TimelinePoint {
        var sessionTotals: [String: Int] = [:]
        var tokens = 0
        var costSum = 0.0
        for entry in slice {
            let total = entry.totalTokens
            tokens += total
            costSum += cost(of: entry)
            sessionTotals["\(entry.projectPath)/\(entry.sessionId)", default: 0] += total
        }
        let dominant = sessionTotals.max { $0.value < $1.value }
        return TimelinePoint(
            timestamp: start,
            label: label,
            tokens: tokens,
            costUSD: costSum,
            topSession: dominant?.key,
            topSessionTokens: dominant?.value ?? 0
        )
    }

    private func startOfDay(_ date: Date) -> Date {
        calendar.startOfDay(for: date)
    }

    private func startOfWeek(_ date: Date) -> Date {
        var cal = calendar
        cal.firstDayOfTheWeek = max(1, min(7, weekStart))
        let weekday = cal.component(.weekday, from: date)
        let offset = (weekday - cal.firstDayOfTheWeek + 7) % 7
        return cal.date(byAdding: .day, value: -offset, to: cal.startOfDay(for: date)) ?? date
    }

    private func startOfMonth(_ date: Date) -> Date {
        let components = calendar.dateComponents([.year, .month], from: date)
        return calendar.date(from: components) ?? date
    }

    private func daysInCurrentMonth(_ date: Date) -> Int {
        calendar.range(of: .day, in: .month, for: date)?.count ?? 30
    }

    private func groupByDateString(_ entries: [UsageEntry], key: (Date) -> String) -> [AggregateBucket] {
        var buckets: [String: BucketAccumulator] = [:]
        for entry in entries {
            let id = key(entry.timestamp)
            buckets[id, default: BucketAccumulator(id: id, key: id)].add(entry, cost: cost(of: entry))
        }
        return buckets.values.map { $0.finalize() }.sorted { $0.id > $1.id }
    }

    private func groupBySession(_ entries: [UsageEntry]) -> [AggregateBucket] {
        var buckets: [String: BucketAccumulator] = [:]
        for entry in entries {
            let id = "\(entry.projectPath)/\(entry.sessionId)"
            buckets[id, default: BucketAccumulator(id: id, key: id)].add(entry, cost: cost(of: entry))
        }
        return buckets.values.map { $0.finalize() }.sorted {
            ($0.end ?? .distantPast) > ($1.end ?? .distantPast)
        }
    }

    private func groupByFiveHourBlock(_ entries: [UsageEntry], now: Date) -> [AggregateBucket] {
        let blocks = SessionBlockBuilder().build(entries: entries, now: now)
        return blocks.map { block -> AggregateBucket in
            var acc = BucketAccumulator(id: block.id, key: Self.shortRange(block.start, block.end))
            acc.start = block.start
            acc.end = block.end
            acc.isActive = block.isActive
            acc.isGap = block.isGap
            for entry in block.entries {
                acc.add(entry, cost: cost(of: entry))
            }
            return acc.finalize()
        }.sorted { $0.start ?? .distantPast > $1.start ?? .distantPast }
    }

    static func dayKey(for date: Date, calendar: Calendar) -> String {
        let comps = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", comps.year ?? 0, comps.month ?? 0, comps.day ?? 0)
    }

    static func monthKey(for date: Date, calendar: Calendar) -> String {
        let comps = calendar.dateComponents([.year, .month], from: date)
        return String(format: "%04d-%02d", comps.year ?? 0, comps.month ?? 0)
    }

    static func weekKey(for date: Date, calendar: Calendar, weekStart: Int) -> String {
        var cal = calendar
        cal.firstDayOfTheWeek = max(1, min(7, weekStart))
        let weekday = cal.component(.weekday, from: date)
        let offset = (weekday - cal.firstDayOfTheWeek + 7) % 7
        let weekDate = cal.date(byAdding: .day, value: -offset, to: date) ?? date
        return dayKey(for: weekDate, calendar: cal)
    }

    static func shortRange(_ start: Date, _ end: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d, HH:mm"
        return "\(formatter.string(from: start)) → \(formatter.string(from: end))"
    }
}

private extension Calendar {
    var firstDayOfTheWeek: Int {
        get { firstWeekday }
        set { firstWeekday = newValue }
    }
}

enum PricingResolver {
    static func resolve(model: String?, table: [String: ModelPricing]) -> ModelPricing? {
        guard let model, !model.isEmpty else { return nil }
        for prefix in PricingService.prefixCandidates {
            if let hit = table[prefix + model] { return hit }
        }
        let lower = model.lowercased()
        return table.first { entry in
            let key = entry.key.lowercased()
            return key.contains(lower) || lower.contains(key)
        }?.value
    }
}

private struct BucketAccumulator {
    let id: String
    let key: String
    var start: Date?
    var end: Date?
    var inputTokens = 0
    var outputTokens = 0
    var cacheCreationTokens = 0
    var cacheReadTokens = 0
    var costUSD: Double = 0
    var perModel: [String: PerModelAccumulator] = [:]
    var isActive = false
    var isGap = false

    init(id: String, key: String) {
        self.id = id
        self.key = key
    }

    mutating func add(_ entry: UsageEntry, cost: Double) {
        inputTokens += entry.inputTokens
        outputTokens += entry.outputTokens
        cacheCreationTokens += entry.cacheCreationTokens
        cacheReadTokens += entry.cacheReadTokens
        costUSD += cost
        if let earliest = start { start = min(earliest, entry.timestamp) } else { start = entry.timestamp }
        if let latest = end { end = max(latest, entry.timestamp) } else { end = entry.timestamp }

        let modelKey = entry.model ?? "unknown"
        var per = perModel[modelKey] ?? PerModelAccumulator(model: modelKey)
        per.add(entry, cost: cost)
        perModel[modelKey] = per
    }

    func finalize() -> AggregateBucket {
        let models = perModel.values
            .map { $0.finalize() }
            .sorted { $0.totalTokens > $1.totalTokens }
        return AggregateBucket(
            id: id,
            key: key,
            start: start,
            end: end,
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            cacheCreationTokens: cacheCreationTokens,
            cacheReadTokens: cacheReadTokens,
            costUSD: costUSD,
            models: models,
            isActive: isActive,
            isGap: isGap
        )
    }
}

private struct PerModelAccumulator {
    let model: String
    var inputTokens = 0
    var outputTokens = 0
    var cacheCreationTokens = 0
    var cacheReadTokens = 0
    var costUSD: Double = 0

    mutating func add(_ entry: UsageEntry, cost: Double) {
        inputTokens += entry.inputTokens
        outputTokens += entry.outputTokens
        cacheCreationTokens += entry.cacheCreationTokens
        cacheReadTokens += entry.cacheReadTokens
        costUSD += cost
    }

    func finalize() -> ModelBreakdown {
        ModelBreakdown(
            model: model,
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            cacheCreationTokens: cacheCreationTokens,
            cacheReadTokens: cacheReadTokens,
            costUSD: costUSD
        )
    }
}

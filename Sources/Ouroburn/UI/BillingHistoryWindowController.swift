import AppKit

/// Day-by-day Anthropic OAuth spend history rendered as an NSOutlineView. Top-level rows are
/// per-day rollups; expanding a row shows every individual sample with its diff against the
/// previous sample. Distinct data source from the local pricing aggregate (this reads the
/// rolling JSONL written by `BillingService` on each successful `/api/oauth/usage` fetch).
@MainActor
final class BillingHistoryWindowController: NSWindowController {
    private let store = BillingSampleStore()
    private let outline = NSOutlineView()
    private var dayRows: [DayRow] = []
    private let timeColumnID = NSUserInterfaceItemIdentifier("time")
    private let totalColumnID = NSUserInterfaceItemIdentifier("total")
    private let deltaColumnID = NSUserInterfaceItemIdentifier("delta")
    private let rateColumnID = NSUserInterfaceItemIdentifier("rate")
    private let sourceColumnID = NSUserInterfaceItemIdentifier("source")
    private let dataSourceProxy = OutlineProxy()

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 600),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Anthropic spend history"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .visible
        window.backgroundColor = Theme.background
        window.minSize = NSSize(width: 520, height: 360)
        window.isReleasedWhenClosed = false
        window.center()

        super.init(window: window)
        dataSourceProxy.controller = self
        window.contentViewController = makeContentViewController()
        reload()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not used") }

    func showOnTop() {
        reload()
        showWindow(self)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func makeContentViewController() -> NSViewController {
        let vc = NSViewController()
        let root = NSView()
        root.wantsLayer = true
        root.layer?.backgroundColor = Theme.background.cgColor

        outline.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        outline.usesAlternatingRowBackgroundColors = true
        outline.allowsColumnResizing = true
        outline.headerView = NSTableHeaderView()
        outline.rowSizeStyle = .small
        outline.indentationPerLevel = 12
        outline.autoresizesOutlineColumn = true
        outline.dataSource = dataSourceProxy
        outline.delegate = dataSourceProxy
        outline.gridStyleMask = [.solidHorizontalGridLineMask]
        outline.intercellSpacing = NSSize(width: 8, height: 4)
        outline.backgroundColor = Theme.background
        outline.style = .inset
        outline.translatesAutoresizingMaskIntoConstraints = false

        let timeColumn = NSTableColumn(identifier: timeColumnID)
        timeColumn.title = "Time"
        timeColumn.minWidth = 110
        timeColumn.width = 150
        outline.addTableColumn(timeColumn)
        outline.outlineTableColumn = timeColumn

        let totalColumn = NSTableColumn(identifier: totalColumnID)
        totalColumn.title = "MTD"
        totalColumn.minWidth = 80
        totalColumn.width = 96
        outline.addTableColumn(totalColumn)

        let deltaColumn = NSTableColumn(identifier: deltaColumnID)
        deltaColumn.title = "Δ"
        deltaColumn.minWidth = 70
        deltaColumn.width = 90
        outline.addTableColumn(deltaColumn)

        let rateColumn = NSTableColumn(identifier: rateColumnID)
        rateColumn.title = "$/hr"
        rateColumn.minWidth = 70
        rateColumn.width = 90
        outline.addTableColumn(rateColumn)

        let sourceColumn = NSTableColumn(identifier: sourceColumnID)
        sourceColumn.title = "Source"
        sourceColumn.minWidth = 90
        sourceColumn.width = 130
        outline.addTableColumn(sourceColumn)

        let scroll = NSScrollView()
        scroll.documentView = outline
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false

        root.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: root.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor)
        ])
        vc.view = root
        return vc
    }

    private func reload() {
        let samples = store.load().sorted { $0.timestamp < $1.timestamp }
        let calendar = Calendar.current

        // Build paired (sample, prior) so each row already knows its diff context.
        var paired: [(sample: BillingSample, prior: BillingSample?)] = []
        paired.reserveCapacity(samples.count)
        for (i, sample) in samples.enumerated() {
            let prior = i == 0 ? nil : samples[i - 1]
            paired.append((sample, prior))
        }

        // Group by day, newest day first.
        var groups: [Date: [(sample: BillingSample, prior: BillingSample?)]] = [:]
        var dayOrder: [Date] = []
        for entry in paired {
            let dayStart = calendar.startOfDay(for: entry.sample.timestamp)
            if groups[dayStart] == nil { dayOrder.append(dayStart) }
            groups[dayStart, default: []].append(entry)
        }
        dayOrder.sort(by: >)

        var rows: [DayRow] = []
        for day in dayOrder {
            let entries = groups[day] ?? []
            let first = entries.first?.sample.totalUSD ?? 0
            let last = entries.last?.sample.totalUSD ?? 0
            let dayDelta = entries.first.flatMap { $0.prior }
                .map { entries.last!.sample.totalUSD - $0.totalUSD }
                ?? max(0, last - first)
            // Show samples newest-first inside the day.
            let ordered = entries.sorted { $0.sample.timestamp > $1.sample.timestamp }
            rows.append(DayRow(day: day, samples: ordered, latest: last, dayDelta: dayDelta))
        }

        dayRows = rows
        outline.reloadData()

        // Auto-expand the most-recent day so the user sees today's samples without a click.
        if let first = dayRows.first {
            outline.expandItem(first)
        }
    }

    // Outline data hooks called from the proxy.
    fileprivate func numberOfChildren(of item: Any?) -> Int {
        if item == nil { return dayRows.count }
        if let day = item as? DayRow { return day.samples.count }
        return 0
    }

    fileprivate func child(_ index: Int, of item: Any?) -> Any {
        if item == nil { return dayRows[index] }
        if let day = item as? DayRow { return day.samples[index].sample }
        return ""
    }

    fileprivate func isItemExpandable(_ item: Any) -> Bool {
        if let day = item as? DayRow { return !day.samples.isEmpty }
        return false
    }

    fileprivate func priorFor(sample: BillingSample) -> BillingSample? {
        for day in dayRows {
            for entry in day.samples where entry.sample.timestamp == sample.timestamp {
                return entry.prior
            }
        }
        return nil
    }

    fileprivate func viewFor(column id: NSUserInterfaceItemIdentifier, item: Any) -> NSView? {
        if let day = item as? DayRow {
            return dayCell(column: id, row: day)
        }
        if let sample = item as? BillingSample {
            return sampleCell(column: id, sample: sample, prior: priorFor(sample: sample))
        }
        return nil
    }

    private func dayCell(column id: NSUserInterfaceItemIdentifier, row: DayRow) -> NSView {
        switch id {
        case timeColumnID:
            let formatter = DateFormatter()
            formatter.dateFormat = "EEE · MMM d"
            return makeLabel(formatter.string(from: row.day), font: Theme.titleFont(size: 12),
                             color: Theme.textPrimary)
        case totalColumnID:
            return makeLabel(String(format: "$%.2f", row.latest), font: Theme.numericFont(size: 12),
                             color: Theme.accentMint)
        case deltaColumnID:
            return makeLabel(String(format: "$%+.2f", row.dayDelta), font: Theme.numericFont(size: 12),
                             color: deltaColor(value: row.dayDelta))
        case rateColumnID:
            // Day-level "$/hr" uses sample span / dollar delta for that day.
            if let firstSample = row.samples.last?.sample,
               let lastSample = row.samples.first?.sample,
               lastSample.timestamp > firstSample.timestamp
            {
                let secs = lastSample.timestamp.timeIntervalSince(firstSample.timestamp)
                let perHour = row.dayDelta * 3600 / secs
                return makeLabel(String(format: "$%+.2f", perHour),
                                 font: Theme.numericFont(size: 12),
                                 color: deltaColor(value: perHour))
            }
            return makeLabel("—", font: Theme.numericFont(size: 12), color: Theme.textTertiary)
        case sourceColumnID:
            return makeLabel("\(row.samples.count) samples",
                             font: Theme.bodyFont(size: 11),
                             color: Theme.textTertiary)
        default:
            return NSView()
        }
    }

    private func sampleCell(
        column id: NSUserInterfaceItemIdentifier,
        sample: BillingSample,
        prior: BillingSample?
    ) -> NSView {
        switch id {
        case timeColumnID:
            let formatter = DateFormatter()
            formatter.dateFormat = "HH:mm:ss"
            return makeLabel(formatter.string(from: sample.timestamp),
                             font: Theme.numericFont(size: 11),
                             color: Theme.textSecondary)
        case totalColumnID:
            return makeLabel(String(format: "$%.2f", sample.totalUSD),
                             font: Theme.numericFont(size: 11),
                             color: Theme.textPrimary)
        case deltaColumnID:
            guard let prior else {
                return makeLabel("—", font: Theme.numericFont(size: 11), color: Theme.textTertiary)
            }
            let delta = sample.totalUSD - prior.totalUSD
            return makeLabel(String(format: "$%+.2f", delta),
                             font: Theme.numericFont(size: 11),
                             color: deltaColor(value: delta))
        case rateColumnID:
            guard let prior else {
                return makeLabel("—", font: Theme.numericFont(size: 11), color: Theme.textTertiary)
            }
            let elapsed = sample.timestamp.timeIntervalSince(prior.timestamp)
            guard elapsed > 0 else {
                return makeLabel("—", font: Theme.numericFont(size: 11), color: Theme.textTertiary)
            }
            let perHour = (sample.totalUSD - prior.totalUSD) * 3600 / elapsed
            return makeLabel(String(format: "$%+.2f", perHour),
                             font: Theme.numericFont(size: 11),
                             color: deltaColor(value: perHour))
        case sourceColumnID:
            return makeLabel(sample.source,
                             font: Theme.bodyFont(size: 10),
                             color: Theme.textTertiary)
        default:
            return NSView()
        }
    }

    private func deltaColor(value: Double) -> NSColor {
        if value > 1 { return Theme.accentRed }
        if value > 0.05 { return Theme.accentPeach }
        if value > 0 { return Theme.accentLime }
        return Theme.textTertiary
    }

    private func makeLabel(_ string: String, font: NSFont, color: NSColor) -> NSView {
        let label = NSTextField(labelWithString: string)
        label.font = font
        label.textColor = color
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        let cell = NSView()
        cell.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
            label.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -4),
            label.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
        ])
        return cell
    }
}

private struct DayRow {
    let day: Date
    let samples: [(sample: BillingSample, prior: BillingSample?)]
    let latest: Double
    let dayDelta: Double
}

/// Outline view delegate + data source proxy. Kept private because NSOutlineView's protocols
/// require `@MainActor` conformance that's awkward to mix with the parent controller.
@MainActor
private final class OutlineProxy: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate {
    weak var controller: BillingHistoryWindowController?

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        controller?.numberOfChildren(of: item) ?? 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        controller?.child(index, of: item) ?? ""
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        controller?.isItemExpandable(item) ?? false
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?,
                     item: Any) -> NSView?
    {
        guard let id = tableColumn?.identifier else { return nil }
        return controller?.viewFor(column: id, item: item)
    }
}

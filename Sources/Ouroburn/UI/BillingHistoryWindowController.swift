import AppKit

/// Day-by-day Anthropic OAuth spend history rendered as an NSOutlineView. Top-level rows are
/// per-day rollups; expanding a row shows every individual sample with its diff against the
/// previous sample. Distinct data source from the local pricing aggregate (this reads the
/// rolling JSONL written by `BillingService` on each successful `/api/oauth/usage` fetch).
@MainActor
final class BillingHistoryWindowController: NSWindowController {
    private let store = BillingSampleStore()
    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEE · MMM d"
        return f
    }()

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    private let outline = NSOutlineView()
    private var dayRows: [DayRow] = []
    private let timeColumnID = NSUserInterfaceItemIdentifier("time")
    private let totalColumnID = NSUserInterfaceItemIdentifier("total")
    private let deltaColumnID = NSUserInterfaceItemIdentifier("delta")
    private let dataSourceProxy = OutlineProxy()

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 880, height: 680),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Anthropic spend history"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .visible
        window.backgroundColor = Theme.background
        window.minSize = NSSize(width: 720, height: 480)
        window.isReleasedWhenClosed = false
        window.center()

        super.init(window: window)
        dataSourceProxy.controller = self
        window.contentViewController = makeContentViewController()
        // Defer first reload to `showOnTop`; constructing the controller without showing the
        // window was eagerly parsing 3k+ samples on app launch.
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("not used")
    }

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
        outline.rowSizeStyle = .default
        outline.rowHeight = 26
        outline.indentationPerLevel = 16
        outline.autoresizesOutlineColumn = true
        outline.dataSource = dataSourceProxy
        outline.delegate = dataSourceProxy
        outline.gridStyleMask = [.solidHorizontalGridLineMask]
        outline.intercellSpacing = NSSize(width: 10, height: 6)
        outline.backgroundColor = Theme.background
        outline.style = .inset
        outline.translatesAutoresizingMaskIntoConstraints = false

        let timeColumn = NSTableColumn(identifier: timeColumnID)
        timeColumn.title = "Time"
        timeColumn.minWidth = 160
        timeColumn.width = 220
        outline.addTableColumn(timeColumn)
        outline.outlineTableColumn = timeColumn

        let totalColumn = NSTableColumn(identifier: totalColumnID)
        totalColumn.title = "MTD"
        totalColumn.minWidth = 100
        totalColumn.width = 130
        outline.addTableColumn(totalColumn)

        let deltaColumn = NSTableColumn(identifier: deltaColumnID)
        deltaColumn.title = "Δ"
        deltaColumn.minWidth = 90
        deltaColumn.width = 140
        outline.addTableColumn(deltaColumn)

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

        // MTD column shows Anthropic's `extra_used_usd` as-is — the last sample of the day. This
        // matches what the OAuth API reports and what the user sees in Anthropic's console. A
        // prior implementation synthesized a "reset-robust" running total by summing positive
        // deltas across the month, but unfiltered troughs (Anthropic glitches that didn't
        // recover within 30 min because the laptop slept) caused the recovery jump to be
        // counted as growth and inflated the row by thousands of dollars.
        var rows: [DayRow] = []
        for day in dayOrder {
            let entries = groups[day] ?? []
            let first = entries.first?.sample.totalUSD ?? 0
            let last = entries.last?.sample.totalUSD ?? 0
            let dayDelta = max(0, last - first)
            let ordered = entries.sorted { $0.sample.timestamp > $1.sample.timestamp }
            rows.append(DayRow(day: day, samples: ordered, latest: last, dayDelta: dayDelta))
        }

        dayRows = rows
        outline.reloadData()
        // Auto-expand the most-recent day so the user lands on today's samples without a click.
        // Deferred to the next runloop tick because `expandItem(_:)` against an item that
        // NSOutlineView hasn't yet materialized via `child(_:ofItem:)` is a no-op. After the
        // reload tick the view has the same DayRow reference that the data source returns.
        DispatchQueue.main.async { [weak self] in
            guard let self, let first = dayRows.first else { return }
            outline.expandItem(first)
            // Scroll the freshly-expanded day into view so the user sees today's samples even
            // when the table has already accumulated a long history above it.
            outline.scrollRowToVisible(0)
        }
    }

    /// Outline data hooks called from the proxy.
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
            makeLabel(
                Self.dayFormatter.string(from: row.day),
                font: Theme.titleFont(size: 12),
                color: Theme.textPrimary
            )
        case totalColumnID:
            // MTD reflects cumulative *spend* — render neutral, not the accent-mint we use for
            // positive/credit deltas. Otherwise the column reads as "money in" even though it's
            // money out.
            makeLabel(
                NumberFormatting.compactDollars(row.latest),
                font: Theme.numericFont(size: 12),
                color: Theme.textPrimary
            )
        case deltaColumnID:
            makeLabel(
                NumberFormatting.compactDollars(row.dayDelta),
                font: Theme.numericFont(size: 12),
                color: deltaColor(value: row.dayDelta)
            )
        default:
            NSView()
        }
    }

    private func sampleCell(
        column id: NSUserInterfaceItemIdentifier,
        sample: BillingSample,
        prior: BillingSample?
    ) -> NSView {
        switch id {
        case timeColumnID:
            return makeLabel(
                Self.timeFormatter.string(from: sample.timestamp),
                font: Theme.numericFont(size: 11),
                color: Theme.textSecondary
            )
        case totalColumnID:
            return makeLabel(
                NumberFormatting.compactDollars(sample.totalUSD),
                font: Theme.numericFont(size: 11),
                color: Theme.textPrimary
            )
        case deltaColumnID:
            guard let prior else {
                return makeLabel("—", font: Theme.numericFont(size: 11), color: Theme.textTertiary)
            }
            let delta = sample.totalUSD - prior.totalUSD
            return makeLabel(
                NumberFormatting.compactDollars(delta),
                font: Theme.numericFont(size: 11),
                color: deltaColor(value: delta)
            )
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

/// Reference type so NSOutlineView can match `expandItem(_:)` against the same identity it
/// hands back from `child(_:ofItem:)`. Earlier this was a struct — value-type identity broke
/// auto-expand because each `child` call materialized a fresh copy.
private final class DayRow {
    let day: Date
    let samples: [(sample: BillingSample, prior: BillingSample?)]
    let latest: Double
    let dayDelta: Double

    init(day: Date, samples: [(sample: BillingSample, prior: BillingSample?)], latest: Double, dayDelta: Double) {
        self.day = day
        self.samples = samples
        self.latest = latest
        self.dayDelta = dayDelta
    }
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

    func outlineView(
        _ outlineView: NSOutlineView,
        viewFor tableColumn: NSTableColumn?,
        item: Any
    ) -> NSView? {
        guard let id = tableColumn?.identifier else { return nil }
        return controller?.viewFor(column: id, item: item)
    }
}

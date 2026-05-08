import AppKit

@MainActor
final class StatusBarController {
    var onShowSettings: (() -> Void)?
    var onRevealLogs: (() -> Void)?
    var onLoginRequested: (() -> Void)?
    var onShowSpendHistory: (() -> Void)?

    private let item: NSStatusItem
    private let iconView: OuroborosView
    private let popover = NSPopover()
    private let metrics = MetricsViewController()
    private let tracker: BurnTracker
    private lazy var contextMenu: NSMenu = buildContextMenu()

    init(tracker: BurnTracker) {
        self.tracker = tracker
        item = NSStatusBar.system.statusItem(withLength: 28)
        iconView = OuroborosView(frame: NSRect(x: 0, y: 0, width: 22, height: 22))
        iconView.translatesAutoresizingMaskIntoConstraints = false

        if let button = item.button {
            button.addSubview(iconView)
            button.target = self
            button.action = #selector(handleClick(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            NSLayoutConstraint.activate([
                iconView.centerXAnchor.constraint(equalTo: button.centerXAnchor),
                iconView.centerYAnchor.constraint(equalTo: button.centerYAnchor),
                iconView.widthAnchor.constraint(equalToConstant: 22),
                iconView.heightAnchor.constraint(equalToConstant: 22)
            ])
        }

        popover.behavior = .transient
        popover.animates = true
        popover.appearance = NSAppearance(named: .vibrantDark)
        popover.contentViewController = metrics

        metrics.onModeChange = { [weak tracker] mode in tracker?.setMode(mode) }
        metrics.onLoginClick = { [weak self] in self?.onLoginRequested?() }
        metrics.onMonthlyTileClick = { [weak self] in self?.onShowSpendHistory?() }
        metrics.setConnectionState(
            OAuthCredentialStore.load() != nil ? .connected(spendUSD: nil) : .disconnected
        )
    }

    func setConnectionState(_ state: MetricsViewController.ConnectionState) {
        metrics.setConnectionState(state)
    }

    func render(snapshot: TrackerSnapshot) {
        iconView.update(liveRate: snapshot.tokensPerMinute, medianRate: snapshot.medianTokensPerMinute)
        metrics.update(snapshot: snapshot)
        if let button = item.button {
            button.toolTip = String(
                format: "ouroburn — %.0f tok/min · ~$%.2f/hr",
                snapshot.tokensPerMinute, snapshot.costPerHour
            )
        }
    }

    func setRefreshState(_ state: RefreshState) {
        metrics.setRefreshState(state)
        if let button = item.button, state.isRefreshing {
            button.toolTip = "ouroburn — \(state.message)"
        }
    }

    @objc private func handleClick(_: Any?) {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp {
            showContextMenu()
        } else {
            togglePopover()
        }
    }

    private func togglePopover() {
        guard let button = item.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    private func showContextMenu() {
        guard let button = item.button else { return }
        Log.info(Log.ui, "Context menu requested")
        let location = NSPoint(x: 0, y: button.bounds.height + 4)
        contextMenu.popUp(positioning: nil, at: location, in: button)
    }

    private func buildContextMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(makeMenuItem(title: "Open ouroburn", symbol: "flame", action: #selector(openPopover(_:))))
        menu.addItem(makeMenuItem(
            title: "Refresh now",
            symbol: "arrow.clockwise",
            action: #selector(refreshNow(_:))
        ))
        menu.addItem(.separator())
        menu.addItem(makeMenuItem(title: "Settings…", symbol: "gearshape", action: #selector(openSettings(_:))))
        menu.addItem(makeMenuItem(
            title: "Reveal logs in Finder",
            symbol: "doc.text.magnifyingglass",
            action: #selector(revealLogs(_:))
        ))
        menu.addItem(.separator())
        menu.addItem(makeMenuItem(
            title: "Quit ouroburn",
            symbol: "power",
            action: #selector(NSApplication.terminate(_:))
        ))
        return menu
    }

    @objc private func refreshNow(_: Any?) {
        Log.info(Log.ui, "Refresh now menu item triggered")
        tracker.forceRefresh()
    }

    private func makeMenuItem(title: String, symbol: String, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        if let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) {
            image.isTemplate = true
            item.image = image
        }
        return item
    }

    @objc private func openPopover(_: Any?) {
        togglePopover()
    }

    @objc private func openSettings(_: Any?) {
        Log.info(Log.ui, "openSettings menu item triggered")
        if popover.isShown { popover.performClose(nil) }
        onShowSettings?()
    }

    @objc private func revealLogs(_: Any?) {
        onRevealLogs?()
    }
}

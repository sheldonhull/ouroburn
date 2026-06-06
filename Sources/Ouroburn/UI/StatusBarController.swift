import AppKit

@MainActor
final class StatusBarController: NSObject, NSMenuItemValidation {
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
        item = NSStatusBar.system.statusItem(withLength: 32)
        iconView = OuroborosView(frame: NSRect(x: 0, y: 0, width: 26, height: 22))
        iconView.translatesAutoresizingMaskIntoConstraints = false
        super.init()

        if let button = item.button {
            button.addSubview(iconView)
            button.target = self
            button.action = #selector(handleClick(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            NSLayoutConstraint.activate([
                iconView.centerXAnchor.constraint(equalTo: button.centerXAnchor),
                iconView.centerYAnchor.constraint(equalTo: button.centerYAnchor),
                iconView.widthAnchor.constraint(equalToConstant: 26),
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
        tracker.onPricingStatus = { [weak metrics] date in
            DispatchQueue.main.async { metrics?.setPricingAge(date) }
        }
        metrics.onRefreshPricingClick = { [weak tracker, weak metrics] in
            tracker?.refreshPricingManually { date in
                DispatchQueue.main.async {
                    metrics?.setPricingAge(date)
                    metrics?.setPricingRefreshing(false)
                }
            }
        }
        // Keychain access can pop a TCC prompt that blocks indefinitely if the user doesn't
        // notice it (menu-bar app, no front window). Defer the credential probe so app launch
        // isn't gated on Keychain availability. The connection chip starts as `.disconnected`;
        // the async probe upgrades it once the system responds.
        metrics.setConnectionState(.disconnected)
        DispatchQueue.global(qos: .utility).async { [weak metrics] in
            let hasCredential = OAuthCredentialStore.load() != nil
            guard hasCredential else { return }
            DispatchQueue.main.async {
                metrics?.setConnectionState(.connected(spendUSD: nil))
            }
        }
    }

    func setConnectionState(_ state: MetricsViewController.ConnectionState) {
        metrics.setConnectionState(state)
    }

    func render(snapshot: TrackerSnapshot) {
        // Spinner reflects OAuth-billed burn only — local JSONL (which a non-billed Teams session
        // still writes) must not move it. Color ← burn/median, speed ← last sample block.
        iconView.update(
            burnUSDPerHour: snapshot.oauthBurnUSDPerHour,
            medianUSDPerHour: snapshot.oauthMedianBurnUSDPerHour
        )
        metrics.update(snapshot: snapshot)
        if let button = item.button {
            button.toolTip = "ouroburn — "
                + NumberFormatting.compactRate(tokensPerMinute: snapshot.tokensPerMinute)
                + " · "
                + NumberFormatting.compactRate(dollarsPerHour: snapshot.costPerHour)
        }
    }

    func applyLive(snapshot: LiveSnapshot) {
        metrics.applyLive(snapshot: snapshot)
        // The spinner is OAuth-driven (see `render`); live JSONL only refreshes the tooltip text
        // while the popover is open. Skip when the rolling window is idle so the tooltip doesn't
        // flicker between live and 60s values.
        guard snapshot.tokensPerMinute > 0 else { return }
        if let button = item.button {
            button.toolTip = "ouroburn — "
                + NumberFormatting.compactRate(tokensPerMinute: snapshot.tokensPerMinute)
                + " · "
                + NumberFormatting.compactRate(dollarsPerHour: snapshot.costPerHour)
        }
    }

    func applyBillingHealth(_ health: BillingHealth) {
        metrics.applyBillingHealth(health)
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
            tracker.stopLiveTracking()
        } else {
            // Refresh the live priority panel from the cached snapshot before the popover slides
            // in so the OAuth heartbeat + top-5 sessions read fresh on every open.
            metrics.popoverWillShow()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
            // Tail-read JSONLs every 2s while the popover is visible. Stops on close so we don't
            // pay incremental I/O when nobody is looking at the numbers.
            tracker.startLiveTracking()
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
        // Without `autoenablesItems = false`, NSMenu validates each item against the first
        // responder. On a popUp() from a status bar button, the responder chain often skips this
        // controller, leaving every item disabled. Hard-enable: every menu item has an explicit
        // target+action, so framework validation is redundant.
        menu.autoenablesItems = false
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
        menu.addItem(makeMenuItem(title: "Quit ouroburn", symbol: "power", action: #selector(quitApp(_:))))
        return menu
    }

    @objc private func refreshNow(_: Any?) {
        Log.info(Log.ui, "Refresh now menu item triggered")
        tracker.forceRefresh()
    }

    @objc private func quitApp(_: Any?) {
        Log.info(Log.ui, "Quit menu item triggered")
        NSApp.terminate(nil)
    }

    /// Belt-and-suspenders against NSMenu's responder-chain validation: every menu item we build
    /// targets methods on this controller, so each one is unconditionally valid. autoenablesItems
    /// is already off, but leaving this in lets us flip it back on later without re-debugging.
    nonisolated func validateMenuItem(_: NSMenuItem) -> Bool {
        true
    }

    private func makeMenuItem(title: String, symbol: String, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.isEnabled = true
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

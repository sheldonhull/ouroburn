import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusBar: StatusBarController?
    private var tracker: BurnTracker?
    private var notifier: Notifier?
    private var settingsWindow: SettingsWindowController?
    private var spendHistoryWindow: BillingHistoryWindowController?

    func applicationDidFinishLaunching(_: Notification) {
        Log.info(Log.app, "ouroburn launching (bundle=\(Bundle.main.bundleIdentifier ?? "<none>"))")
        let prefs = PreferencesStore.load()

        let pricingURL = DiskCache.defaultPricingURL()
        let snapshotURL = DiskCache.defaultURL()
        let billingURL = DiskCache.defaultBillingURL()
        let pricing = PricingService(cacheURL: pricingURL)
        let billing = BillingService(cacheURL: billingURL)
        let cache = DiskCache(url: snapshotURL)
        let tracker = BurnTracker(pricingService: pricing, billingService: billing, cache: cache)
        tracker.applyPreferences(prefs)
        tracker.setMode(prefs.defaultMode)
        let statusBar = StatusBarController(tracker: tracker)
        let notifier: Notifier? = Bundle.main.bundleIdentifier != nil
            ? Notifier(cooldown: prefs.notificationCooldownSeconds)
            : nil

        self.tracker = tracker
        self.statusBar = statusBar
        self.notifier = notifier

        // Wire callbacks BEFORE calling render. A heavy bootstrap render can deadlock or stall
        // the main run loop (the popover view tree gets force-loaded with 700+ rows), and we
        // never want a slow render to leave the menu's Settings hook unwired.
        tracker.onUpdate = { [weak statusBar] snapshot in
            DispatchQueue.main.async { statusBar?.render(snapshot: snapshot) }
        }
        tracker.onSpike = { [weak notifier] snapshot in
            DispatchQueue.main.async {
                notifier?.deliverSpike(
                    currentRate: snapshot.tokensPerMinute,
                    previousRate: snapshot.previousTokensPerMinute,
                    costPerHour: snapshot.costPerHour
                )
            }
        }
        tracker.onRefreshStateChanged = { [weak statusBar] state in
            DispatchQueue.main.async { statusBar?.setRefreshState(state) }
        }
        statusBar.onShowSettings = { [self] in
            Log.info(Log.app, "onShowSettings closure fired")
            showSettings()
        }
        statusBar.onRevealLogs = {
            NSWorkspace.shared.open(Log.fileSink.location.deletingLastPathComponent())
        }
        statusBar.onLoginRequested = { [weak self] in
            self?.handleConnectionToggle()
        }
        statusBar.onShowSpendHistory = { [weak self] in
            self?.showSpendHistory()
        }
        Log.info(Log.app, "Closures wired (onShowSettings=\(statusBar.onShowSettings != nil))")

        if let bootstrap = tracker.bootstrapFromCache() {
            Log.info(Log.app, "Bootstrapped from snapshot cache (\(bootstrap.buckets.count) buckets)")
            // Defer first render so the menu hook is reachable immediately even if rendering
            // 700+ session rows takes a noticeable hit.
            DispatchQueue.main.async { statusBar.render(snapshot: bootstrap) }
        } else {
            Log.info(Log.app, "No snapshot cache found at \(snapshotURL.path)")
        }

        notifier?.requestAuthorization()
        tracker.start()
        Log.info(Log.app, "applicationDidFinishLaunching complete")
    }

    func applicationWillTerminate(_: Notification) {
        Log.info(Log.app, "ouroburn terminating")
        tracker?.stop()
    }

    private func showSpendHistory() {
        if spendHistoryWindow == nil {
            spendHistoryWindow = BillingHistoryWindowController()
        }
        spendHistoryWindow?.showOnTop()
    }

    private func handleConnectionToggle() {
        if OAuthCredentialStore.load() != nil {
            OAuthCredentialStore.clear()
            Log.info(Log.app, "OAuth credential cleared")
            statusBar?.setConnectionState(.disconnected)
            tracker?.forceRefresh()
            return
        }
        statusBar?.setConnectionState(.authorizing)
        Task {
            do {
                let (authURL, completion) = try await OAuthLogin.startLogin()
                NSWorkspace.shared.open(authURL)
                let credential = try await completion()
                OAuthCredentialStore.save(credential)
                Log.info(Log.app, "OAuth login succeeded — credential stored")
                statusBar?.setConnectionState(.connected(spendUSD: nil))
                tracker?.forceRefresh()
            } catch {
                Log.error(Log.app, "OAuth login failed: \(error)")
                statusBar?.setConnectionState(.disconnected)
            }
        }
    }

    private func showSettings() {
        Log.info(Log.app, "showSettings() invoked, existingWindow=\(settingsWindow != nil)")
        if settingsWindow == nil {
            Log.info(Log.app, "Constructing SettingsWindowController")
            settingsWindow = SettingsWindowController(
                logFolderURL: Log.fileSink.location,
                cacheURL: DiskCache.defaultURL(),
                onResetCache: { [weak self] in
                    Log.info(Log.app, "Snapshot cache reset by user")
                    self?.tracker?.setMode(.day)
                },
                onPreferencesSaved: { [weak self] prefs in
                    Log.info(Log.app, "Preferences saved")
                    self?.tracker?.applyPreferences(prefs)
                }
            )
        }
        settingsWindow?.showOnTop()
    }
}

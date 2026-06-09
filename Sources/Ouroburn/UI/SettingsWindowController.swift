import AppKit

@MainActor
final class SettingsWindowController: NSWindowController, NSTextFieldDelegate {
    private let logFolderURL: URL
    private let cacheURL: URL
    private let onResetCache: () -> Void
    private let onResetLocalData: () -> Void
    private let onPreferencesSaved: (Preferences) -> Void
    /// Manual pricing-feed refetch. Hands back the new load time (nil on failure) so the button
    /// can surface freshness. The completion is delivered off the main thread.
    private let onRefreshPricing: (@escaping @Sendable (Date?) -> Void) -> Void

    private let oauthField = NSSecureTextField()
    private let adminField = NSSecureTextField()
    private let oauthIndicator = StatusDot()
    private let adminIndicator = StatusDot()
    private let cooldownField = NSTextField()
    private let oauthIntervalField = NSTextField()
    private let modePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let toastPeakAlertSwitch = NSSwitch()
    private let toastPeakMinimumField = NSTextField()
    private let projectionEnabledSwitch = NSSwitch()
    private let projectionThresholdField = NSTextField()
    private let projectionMinTodayField = NSTextField()
    private let launchAtLoginSwitch = NSSwitch()
    private let toastPreviewButton = NSButton(title: "Preview", target: nil, action: nil)
    private let saveButton = NSButton(title: "Save", target: nil, action: nil)
    private let statusLabel = NSTextField(labelWithString: " ")

    init(
        logFolderURL: URL,
        cacheURL: URL,
        onResetCache: @escaping () -> Void,
        onResetLocalData: @escaping () -> Void,
        onPreferencesSaved: @escaping (Preferences) -> Void,
        onRefreshPricing: @escaping (@escaping @Sendable (Date?) -> Void) -> Void
    ) {
        self.logFolderURL = logFolderURL
        self.cacheURL = cacheURL
        self.onResetCache = onResetCache
        self.onResetLocalData = onResetLocalData
        self.onPreferencesSaved = onPreferencesSaved
        self.onRefreshPricing = onRefreshPricing

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 940),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.minSize = NSSize(width: 640, height: 880)
        window.title = "ouroburn settings"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.backgroundColor = Theme.background
        window.isReleasedWhenClosed = false
        window.center()

        super.init(window: window)
        window.contentViewController = makeContentViewController()
        loadFromStore()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("not used")
    }

    func showOnTop() {
        Log.info(Log.ui, "Settings window showOnTop()")
        loadFromStore()
        guard let window else { return }

        // Accessory apps don't raise on a bare makeKeyAndOrderFront. Force activation, lift the
        // level above ordinary windows for one frame, then drop back so it behaves normally.
        NSApp.activate(ignoringOtherApps: true)
        window.center()
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        window.level = .floating
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        DispatchQueue.main.async {
            window.level = .normal
        }
    }

    // MARK: - Layout

    private func makeContentViewController() -> NSViewController {
        let vc = NSViewController()
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 720, height: 940))
        root.wantsLayer = true
        root.layer?.backgroundColor = Theme.background.cgColor

        let title = NSTextField(labelWithAttributedString:
            Theme.glowAttributedTitle("settings", color: Theme.accentBlue, font: Theme.titleFont(size: 26)))
        title.translatesAutoresizingMaskIntoConstraints = false

        let secretsCard = makeSecretsCard()
        let thresholdsCard = makeThresholdsCard()
        let alertsCard = makeAlertsCard()
        let appCard = makeAppCard()
        let infoCard = makeInfoCard()

        // Scrollable card list — guarantees the Save row stays visible at the bottom regardless
        // of how tall the cards grow or how short the user resizes the window. Cards push the
        // scrollview's intrinsic content height; the scroll wrapper clips when needed.
        let stack = NSStackView(views: [secretsCard, thresholdsCard, alertsCard, appCard, infoCard])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.distribution = .fill
        stack.translatesAutoresizingMaskIntoConstraints = false

        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.autohidesScrollers = true

        let document = NSView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(stack)
        scroll.documentView = document

        saveButton.bezelStyle = .rounded
        saveButton.target = self
        saveButton.action = #selector(savePressed)
        saveButton.contentTintColor = Theme.accentBlue
        saveButton.translatesAutoresizingMaskIntoConstraints = false

        statusLabel.font = Theme.bodyFont(size: 11)
        statusLabel.textColor = Theme.accentLime
        statusLabel.translatesAutoresizingMaskIntoConstraints = false

        root.addSubview(title)
        root.addSubview(scroll)
        root.addSubview(saveButton)
        root.addSubview(statusLabel)

        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: root.topAnchor, constant: 18),
            title.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 22),

            scroll.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 12),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 22),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -22),
            scroll.bottomAnchor.constraint(equalTo: saveButton.topAnchor, constant: -10),

            document.topAnchor.constraint(equalTo: scroll.topAnchor),
            document.leadingAnchor.constraint(equalTo: scroll.leadingAnchor),
            document.trailingAnchor.constraint(equalTo: scroll.trailingAnchor),
            document.widthAnchor.constraint(equalTo: scroll.widthAnchor),

            stack.topAnchor.constraint(equalTo: document.topAnchor, constant: 4),
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -8),

            saveButton.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -22),
            saveButton.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -16),

            statusLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 22),
            statusLabel.centerYAnchor.constraint(equalTo: saveButton.centerYAnchor),
            statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: saveButton.leadingAnchor, constant: -12)
        ])

        vc.view = root
        return vc
    }

    private func makeSecretsCard() -> NSView {
        let card = card(title: "Tokens", subtitle: nil)

        let oauthLabel = makeFieldLabel("Claude OAuth")
        oauthField.translatesAutoresizingMaskIntoConstraints = false
        oauthField.placeholderString = "Bearer token"
        oauthField.delegate = self
        oauthField.target = self
        oauthField.action = #selector(secretFieldCommitted(_:))
        oauthIndicator.translatesAutoresizingMaskIntoConstraints = false

        let adminLabel = makeFieldLabel("Anthropic admin key")
        adminField.translatesAutoresizingMaskIntoConstraints = false
        adminField.placeholderString = "sk-ant-admin01-…"
        adminField.delegate = self
        adminField.target = self
        adminField.action = #selector(secretFieldCommitted(_:))
        adminIndicator.translatesAutoresizingMaskIntoConstraints = false

        let oauthPaste = makeButton(title: "Paste", action: #selector(pasteOAuth(_:)))
        let oauthClear = makeButton(title: "Clear", action: #selector(clearOAuth(_:)))
        let adminPaste = makeButton(title: "Paste", action: #selector(pasteAdmin(_:)))
        let adminClear = makeButton(title: "Clear", action: #selector(clearAdmin(_:)))

        let oauthRow = NSStackView(views: [oauthIndicator, oauthField, oauthPaste, oauthClear])
        oauthRow.orientation = .horizontal
        oauthRow.alignment = .centerY
        oauthRow.spacing = 6
        oauthRow.translatesAutoresizingMaskIntoConstraints = false

        let adminRow = NSStackView(views: [adminIndicator, adminField, adminPaste, adminClear])
        adminRow.orientation = .horizontal
        adminRow.alignment = .centerY
        adminRow.spacing = 6
        adminRow.translatesAutoresizingMaskIntoConstraints = false

        let body = NSStackView(views: [oauthLabel, oauthRow, adminLabel, adminRow])
        body.orientation = .vertical
        body.alignment = .leading
        body.spacing = 6
        body.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(body)
        NSLayoutConstraint.activate([
            body.topAnchor.constraint(equalTo: card.topAnchor, constant: 30),
            body.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 14),
            body.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -14),
            body.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -14),
            oauthRow.widthAnchor.constraint(equalTo: body.widthAnchor, constant: -28),
            adminRow.widthAnchor.constraint(equalTo: body.widthAnchor, constant: -28)
        ])
        return card
    }

    @objc private func pasteOAuth(_: Any?) {
        if let str = NSPasteboard.general.string(forType: .string), !str.isEmpty {
            oauthField.stringValue = str.trimmingCharacters(in: .whitespacesAndNewlines)
            persistSecret(account: SecretsAccount.claudeOAuth, value: oauthField.stringValue, label: "OAuth token")
            oauthIndicator.setActive(true)
        } else {
            statusLabel.stringValue = "Clipboard empty"
        }
    }

    @objc private func clearOAuth(_: Any?) {
        oauthField.stringValue = ""
        Keychain.delete(account: SecretsAccount.claudeOAuth)
        oauthIndicator.setActive(false)
        statusLabel.stringValue = "OAuth token cleared from keychain"
        Log.info(Log.app, "OAuth token cleared")
    }

    @objc private func pasteAdmin(_: Any?) {
        if let str = NSPasteboard.general.string(forType: .string), !str.isEmpty {
            adminField.stringValue = str.trimmingCharacters(in: .whitespacesAndNewlines)
            persistSecret(account: SecretsAccount.anthropicAdmin, value: adminField.stringValue, label: "Admin API key")
            adminIndicator.setActive(true)
        } else {
            statusLabel.stringValue = "Clipboard empty"
        }
    }

    @objc private func clearAdmin(_: Any?) {
        adminField.stringValue = ""
        Keychain.delete(account: SecretsAccount.anthropicAdmin)
        adminIndicator.setActive(false)
        statusLabel.stringValue = "Admin API key cleared from keychain"
        Log.info(Log.app, "Admin API key cleared")
    }

    @objc private func secretFieldCommitted(_ sender: NSTextField) {
        if sender === oauthField {
            persistSecret(account: SecretsAccount.claudeOAuth, value: sender.stringValue, label: "OAuth token")
            oauthIndicator.setActive(!sender.stringValue.isEmpty)
        } else if sender === adminField {
            persistSecret(account: SecretsAccount.anthropicAdmin, value: sender.stringValue, label: "Admin API key")
            adminIndicator.setActive(!sender.stringValue.isEmpty)
        }
    }

    private func persistSecret(account: String, value: String, label: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            Keychain.delete(account: account)
            Log.info(Log.app, "\(label) deleted from keychain")
            statusLabel.stringValue = "\(label) cleared"
        } else {
            Keychain.write(account: account, value: trimmed)
            Log.info(Log.app, "\(label) written to keychain (\(trimmed.count) chars)")
            statusLabel.stringValue = "\(label) saved to keychain"
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
            self?.statusLabel.stringValue = " "
        }
    }

    private func makeThresholdsCard() -> NSView {
        let card = card(title: "Tuning", subtitle: nil)

        cooldownField.translatesAutoresizingMaskIntoConstraints = false
        cooldownField.placeholderString = "600"
        cooldownField.alignment = .right

        oauthIntervalField.translatesAutoresizingMaskIntoConstraints = false
        oauthIntervalField.placeholderString = "5"
        oauthIntervalField.alignment = .right

        modePopup.translatesAutoresizingMaskIntoConstraints = false
        for mode in ViewMode.allCases {
            modePopup.addItem(withTitle: mode.title)
            modePopup.lastItem?.representedObject = mode.rawValue
        }

        let stack = NSStackView(views: [
            inlineRow("Alert cooldown (s)", control: cooldownField, hint: "min 60 between toasts"),
            inlineRow(
                "OAuth refresh (min)",
                control: oauthIntervalField,
                hint: "1–60 baseline · expo backoff up to 15"
            ),
            inlineRow("Default view", control: modePopup, hint: "loaded on launch")
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: card.topAnchor, constant: 38),
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -14),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -14)
        ])
        return card
    }

    /// In-app toast alerts. Two independent signals, both delivered as the floating on-screen toast
    /// (no macOS Notification Center): a new daily peak in OAuth spend rate, and a month-end spend
    /// projection crossing the budget ceiling.
    private func makeAlertsCard() -> NSView {
        let card = card(title: "Alerts", subtitle: nil)

        toastPeakAlertSwitch.translatesAutoresizingMaskIntoConstraints = false

        toastPeakMinimumField.translatesAutoresizingMaskIntoConstraints = false
        toastPeakMinimumField.placeholderString = "5.00"
        toastPeakMinimumField.alignment = .right

        projectionEnabledSwitch.translatesAutoresizingMaskIntoConstraints = false

        projectionThresholdField.translatesAutoresizingMaskIntoConstraints = false
        projectionThresholdField.placeholderString = "7000"
        projectionThresholdField.alignment = .right

        projectionMinTodayField.translatesAutoresizingMaskIntoConstraints = false
        projectionMinTodayField.placeholderString = "200"
        projectionMinTodayField.alignment = .right

        toastPreviewButton.bezelStyle = .rounded
        toastPreviewButton.controlSize = .small
        toastPreviewButton.target = self
        toastPreviewButton.action = #selector(previewToastPressed(_:))
        toastPreviewButton.contentTintColor = Theme.accentPeach
        toastPreviewButton.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [
            inlineRow(
                "Alert on new daily peak",
                control: toastPeakAlertSwitch,
                hint: "today's peak spend rate — last sample $ + period"
            ),
            inlineRow("Peak floor ($/hr)", control: toastPeakMinimumField, hint: "ignore peaks below this"),
            inlineRow(
                "Alert on month projection",
                control: projectionEnabledSwitch,
                hint: "once/day when projected spend crosses budget"
            ),
            inlineRow("Budget ($/month)", control: projectionThresholdField, hint: "projected spend > this"),
            inlineRow(
                "Quiet until today ($)",
                control: projectionMinTodayField,
                hint: "only after today's spend passes this"
            ),
            inlineRow("Preview", control: toastPreviewButton, hint: "fires a sample toast now")
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: card.topAnchor, constant: 38),
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -14),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -14)
        ])
        return card
    }

    @objc private func previewToastPressed(_: Any?) {
        ToastWindow.show(
            title: "Today's peak spend rate (preview)",
            message: "$0.85 in last 6 min · $214 today · sample toast",
            accent: Theme.accentRed
        )
    }

    private func makeAppCard() -> NSView {
        let card = card(title: "App", subtitle: nil)
        launchAtLoginSwitch.translatesAutoresizingMaskIntoConstraints = false
        let stack = NSStackView(views: [
            inlineRow("Launch at login", control: launchAtLoginSwitch, hint: "")
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: card.topAnchor, constant: 38),
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -14),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -14)
        ])
        return card
    }

    private func makeInfoCard() -> NSView {
        let card = card(title: "Diagnostics", subtitle: nil)
        let label = NSTextField(wrappingLabelWithString: """
        Log:       \(logFolderURL.path)
        Snapshot:  \(cacheURL.path)
        """)
        label.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
        label.textColor = Theme.textTertiary
        label.translatesAutoresizingMaskIntoConstraints = false

        let revealLogs = makeButton(title: "Reveal logs", action: #selector(revealLogFolder(_:)))
        let resetCache = makeButton(title: "Reset cache", action: #selector(resetCache(_:)))
        let resetLocal = makeButton(title: "Reset local session data", action: #selector(resetLocalData(_:)))
        let refreshPricing = makeButton(title: "Refresh model pricing", action: #selector(refreshPricingPressed(_:)))
        let actions = NSStackView(views: [revealLogs, resetCache, resetLocal, refreshPricing])
        actions.orientation = .horizontal
        actions.spacing = 8
        actions.translatesAutoresizingMaskIntoConstraints = false

        let hint = NSTextField(wrappingLabelWithString:
            "“Reset local session data” clears the snapshot + parsed-transcript caches and "
                + "re-reads the JSONL from disk. OAuth-tracked billing history is left untouched. "
                + "“Refresh model pricing” refetches the models.dev feed now — use it when a new "
                + "model shows $0.")
        hint.font = Theme.bodyFont(size: 10)
        hint.textColor = Theme.textTertiary
        hint.translatesAutoresizingMaskIntoConstraints = false

        let body = NSStackView(views: [label, actions, hint])
        body.orientation = .vertical
        body.alignment = .leading
        body.spacing = 8
        body.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(body)
        NSLayoutConstraint.activate([
            body.topAnchor.constraint(equalTo: card.topAnchor, constant: 30),
            body.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 14),
            body.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -14),
            body.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -14)
        ])
        return card
    }

    private func card(title: String, subtitle: String?) -> NSView {
        let view = NSView()
        view.wantsLayer = true
        view.layer?.cornerRadius = 12
        view.layer?.backgroundColor = Theme.surface.cgColor
        view.layer?.borderColor = Theme.divider.cgColor
        view.layer?.borderWidth = 1
        view.translatesAutoresizingMaskIntoConstraints = false

        let titleField = NSTextField(labelWithAttributedString:
            Theme.glowAttributedTitle(title.uppercased(), color: Theme.accentBlue, font: Theme.titleFont(size: 11)))
        titleField.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(titleField)
        NSLayoutConstraint.activate([
            titleField.topAnchor.constraint(equalTo: view.topAnchor, constant: 12),
            titleField.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 14)
        ])

        if let subtitle {
            let subtitleField = NSTextField(labelWithString: subtitle)
            subtitleField.font = Theme.bodyFont(size: 10)
            subtitleField.textColor = Theme.textTertiary
            subtitleField.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(subtitleField)
            NSLayoutConstraint.activate([
                subtitleField.topAnchor.constraint(equalTo: titleField.bottomAnchor, constant: 2),
                subtitleField.leadingAnchor.constraint(equalTo: titleField.leadingAnchor),
                subtitleField.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -14)
            ])
        }
        return view
    }

    private func inlineRow(_ label: String, control: NSView, hint: String) -> NSView {
        let labelField = NSTextField(labelWithString: label)
        labelField.font = Theme.bodyFont(size: 11)
        labelField.textColor = Theme.textPrimary
        labelField.translatesAutoresizingMaskIntoConstraints = false

        let hintField = NSTextField(labelWithString: hint)
        hintField.font = Theme.bodyFont(size: 10)
        hintField.textColor = Theme.textTertiary
        hintField.translatesAutoresizingMaskIntoConstraints = false

        control.translatesAutoresizingMaskIntoConstraints = false
        if let text = control as? NSTextField {
            text.bezelStyle = .roundedBezel
            text.font = Theme.numericFont(size: 11)
        }

        let row = NSView()
        row.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(labelField)
        row.addSubview(control)
        row.addSubview(hintField)

        NSLayoutConstraint.activate([
            labelField.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            labelField.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            labelField.widthAnchor.constraint(equalToConstant: 200),

            control.leadingAnchor.constraint(equalTo: labelField.trailingAnchor, constant: 8),
            control.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            control.widthAnchor.constraint(equalToConstant: 96),

            hintField.leadingAnchor.constraint(equalTo: control.trailingAnchor, constant: 12),
            hintField.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            hintField.trailingAnchor.constraint(lessThanOrEqualTo: row.trailingAnchor),

            row.heightAnchor.constraint(greaterThanOrEqualToConstant: 30)
        ])
        return row
    }

    private func makeFieldLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = Theme.bodyFont(size: 11)
        label.textColor = Theme.textSecondary
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }

    private func makeButton(title: String, action: Selector) -> NSButton {
        let b = NSButton(title: title, target: self, action: action)
        b.bezelStyle = .rounded
        b.controlSize = .small
        b.contentTintColor = Theme.accentBlue
        b.translatesAutoresizingMaskIntoConstraints = false
        return b
    }

    // MARK: - Persistence

    private func loadFromStore() {
        let prefs = PreferencesStore.load()
        cooldownField.stringValue = String(Int(prefs.notificationCooldownSeconds))
        oauthIntervalField.stringValue = String(Int(prefs.oauthRefreshMinutes))
        toastPeakAlertSwitch.state = prefs.toastPeakAlertEnabled ? .on : .off
        toastPeakMinimumField.stringValue = String(format: "%.2f", prefs.toastPeakMinimumUSDPerHour)
        projectionEnabledSwitch.state = prefs.monthlyProjectionAlertEnabled ? .on : .off
        projectionThresholdField.stringValue = String(Int(prefs.monthlyProjectionThresholdUSD))
        projectionMinTodayField.stringValue = String(Int(prefs.monthlyProjectionMinTodayUSD))
        launchAtLoginSwitch.state = LaunchAtLogin.isEnabled() ? .on : .off
        if let index = ViewMode.allCases.firstIndex(of: prefs.defaultMode) {
            modePopup.selectItem(at: index)
        }
        let oauth = Keychain.read(account: SecretsAccount.claudeOAuth) ?? ""
        let admin = Keychain.read(account: SecretsAccount.anthropicAdmin) ?? ""
        oauthField.stringValue = oauth
        adminField.stringValue = admin
        oauthIndicator.setActive(!oauth.isEmpty || ProcessInfo.processInfo.environment["CLAUDE_OAUTH_TOKEN"] != nil)
        adminIndicator
            .setActive(!admin.isEmpty || ProcessInfo.processInfo.environment["ANTHROPIC_ADMIN_API_KEY"] != nil)
    }

    @objc private func savePressed() {
        let cooldown = Double(cooldownField.stringValue) ?? Preferences.default.notificationCooldownSeconds
        let oauthInterval = Double(oauthIntervalField.stringValue) ?? Preferences.default.oauthRefreshMinutes
        let mode = ViewMode.allCases[modePopup.indexOfSelectedItem]
        let toastPeakMinimum = Double(toastPeakMinimumField.stringValue)
            ?? Preferences.default.toastPeakMinimumUSDPerHour
        let projectionThreshold = Double(projectionThresholdField.stringValue)
            ?? Preferences.default.monthlyProjectionThresholdUSD
        let projectionMinToday = Double(projectionMinTodayField.stringValue)
            ?? Preferences.default.monthlyProjectionMinTodayUSD

        let wantsLaunchAtLogin = launchAtLoginSwitch.state == .on
        let prefs = Preferences(
            defaultMode: mode,
            notificationCooldownSeconds: max(60, cooldown),
            oauthRefreshMinutes: min(max(1, oauthInterval), 60),
            toastPeakAlertEnabled: toastPeakAlertSwitch.state == .on,
            toastPeakMinimumUSDPerHour: max(0, toastPeakMinimum),
            monthlyProjectionAlertEnabled: projectionEnabledSwitch.state == .on,
            monthlyProjectionThresholdUSD: max(0, projectionThreshold),
            monthlyProjectionMinTodayUSD: max(0, projectionMinToday),
            launchAtLoginEnabled: wantsLaunchAtLogin
        )
        PreferencesStore.save(prefs)
        LaunchAtLogin.apply(enabled: wantsLaunchAtLogin) { [weak self] result in
            guard let self else { return }
            switch result {
            case let .failure(error):
                statusLabel.stringValue = "Launch-at-login: \(error.localizedDescription)"
                launchAtLoginSwitch.state = LaunchAtLogin.isEnabled() ? .on : .off
            case let .success(status):
                switch status {
                case .requiresApproval:
                    statusLabel.stringValue = "Launch-at-login needs approval — opening Login Items"
                    LaunchAtLogin.openLoginItemsSettings()
                    launchAtLoginSwitch.state = .off
                case .enabled, .notRegistered, .notFound, .unknown:
                    launchAtLoginSwitch.state = LaunchAtLogin.isEnabled() ? .on : .off
                }
            }
        }

        let oauth = oauthField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if oauth.isEmpty {
            Keychain.delete(account: SecretsAccount.claudeOAuth)
        } else {
            Keychain.write(account: SecretsAccount.claudeOAuth, value: oauth)
        }
        let admin = adminField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if admin.isEmpty {
            Keychain.delete(account: SecretsAccount.anthropicAdmin)
        } else {
            Keychain.write(account: SecretsAccount.anthropicAdmin, value: admin)
        }
        oauthIndicator.setActive(!oauth.isEmpty)
        adminIndicator.setActive(!admin.isEmpty)
        onPreferencesSaved(prefs)

        statusLabel.stringValue = "Saved · changes apply on next 60s poll"
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
            self?.statusLabel.stringValue = " "
        }
    }

    @objc private func revealLogFolder(_: Any?) {
        NSWorkspace.shared.open(logFolderURL.deletingLastPathComponent())
    }

    @objc private func resetCache(_: Any?) {
        try? FileManager.default.removeItem(at: cacheURL)
        onResetCache()
        statusLabel.stringValue = "Snapshot cache cleared"
    }

    @objc private func resetLocalData(_: Any?) {
        Log.info(Log.app, "Reset local session data requested from settings")
        onResetLocalData()
        statusLabel.stringValue = "Local session data reset — reloading transcripts from disk"
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
            self?.statusLabel.stringValue = " "
        }
    }

    @objc private func refreshPricingPressed(_: Any?) {
        statusLabel.stringValue = "Refreshing model pricing…"
        onRefreshPricing { date in
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if let date {
                    let age = Int(Date().timeIntervalSince(date))
                    statusLabel.stringValue = "Pricing refreshed (\(age)s ago)"
                } else {
                    statusLabel.stringValue = "Pricing refresh failed — keeping cached rates"
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
                    self?.statusLabel.stringValue = " "
                }
            }
        }
    }
}

@MainActor
private final class StatusDot: NSView {
    private let inner = NSView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 10).isActive = true
        heightAnchor.constraint(equalToConstant: 10).isActive = true
        inner.wantsLayer = true
        inner.translatesAutoresizingMaskIntoConstraints = false
        inner.layer?.cornerRadius = 5
        addSubview(inner)
        NSLayoutConstraint.activate([
            inner.widthAnchor.constraint(equalTo: widthAnchor),
            inner.heightAnchor.constraint(equalTo: heightAnchor)
        ])
        setActive(false)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("not used")
    }

    func setActive(_ active: Bool) {
        inner.layer?.backgroundColor = (active ? Theme.accentLime : Theme.textTertiary).cgColor
    }
}

import Foundation

/// User-tunable settings. Non-secret values land in `UserDefaults`; tokens go to the keychain
/// (see `Keychain`). Anything tracked here can be edited from the settings window.
struct Preferences: Sendable {
    var defaultMode: ViewMode
    var notificationCooldownSeconds: Double
    /// Baseline interval (minutes) between Anthropic OAuth spend pulls. Floors at 1, ceilings at
    /// 60. Failed fetches escalate up to `oauthRefreshMaxMinutes` via exponential backoff.
    var oauthRefreshMinutes: Double
    /// Toast on every newly-observed peak in today's per-interval OAuth spend delta — the day's
    /// peak spend rate. Shows the last sample's dollars and how long it covered.
    var toastPeakAlertEnabled: Bool
    /// Floor for peak alerts: a new daily max must also clear this $/hr before firing. Kills
    /// trivial-blip noise (e.g. a $0.40/hr sample beating an even smaller prior max).
    var toastPeakMinimumUSDPerHour: Double
    /// Toast when the month-end spend projection crosses `monthlyProjectionThresholdUSD`. Fires
    /// at most once per day, and only once today's spend has passed `monthlyProjectionMinTodayUSD`
    /// so it stays quiet on light days.
    var monthlyProjectionAlertEnabled: Bool
    var monthlyProjectionThresholdUSD: Double
    var monthlyProjectionMinTodayUSD: Double
    /// Launch the menu-bar app on macOS login via SMAppService.
    var launchAtLoginEnabled: Bool
    static let oauthRefreshMaxMinutes: Double = 15

    static let `default` = Preferences(
        defaultMode: .session,
        notificationCooldownSeconds: 600,
        oauthRefreshMinutes: 5,
        toastPeakAlertEnabled: true,
        toastPeakMinimumUSDPerHour: 5,
        monthlyProjectionAlertEnabled: true,
        monthlyProjectionThresholdUSD: 7000,
        monthlyProjectionMinTodayUSD: 200,
        launchAtLoginEnabled: false
    )
}

@MainActor
enum PreferencesStore {
    private static let defaults = UserDefaults.standard
    private enum Key {
        static let defaultMode = "ouroburn.defaultMode"
        static let notificationCooldown = "ouroburn.notificationCooldown"
        static let oauthRefreshMinutes = "ouroburn.oauthRefreshMinutes"
        static let toastPeakAlertEnabled = "ouroburn.toastPeakAlertEnabled"
        static let toastPeakMinimum = "ouroburn.toastPeakMinimumUSDPerHour"
        static let projectionAlertEnabled = "ouroburn.monthlyProjectionAlertEnabled"
        static let projectionThreshold = "ouroburn.monthlyProjectionThresholdUSD"
        static let projectionMinToday = "ouroburn.monthlyProjectionMinTodayUSD"
        static let launchAtLoginEnabled = "ouroburn.launchAtLoginEnabled"
    }

    static func load() -> Preferences {
        var prefs = Preferences.default
        if let raw = defaults.string(forKey: Key.defaultMode),
           let mode = ViewMode(rawValue: raw)
        {
            prefs.defaultMode = mode
        }
        if defaults.object(forKey: Key.notificationCooldown) != nil {
            prefs.notificationCooldownSeconds = defaults.double(forKey: Key.notificationCooldown)
        }
        if defaults.object(forKey: Key.oauthRefreshMinutes) != nil {
            prefs.oauthRefreshMinutes = defaults.double(forKey: Key.oauthRefreshMinutes)
        }
        if defaults.object(forKey: Key.toastPeakAlertEnabled) != nil {
            prefs.toastPeakAlertEnabled = defaults.bool(forKey: Key.toastPeakAlertEnabled)
        }
        if defaults.object(forKey: Key.toastPeakMinimum) != nil {
            prefs.toastPeakMinimumUSDPerHour = defaults.double(forKey: Key.toastPeakMinimum)
        }
        if defaults.object(forKey: Key.projectionAlertEnabled) != nil {
            prefs.monthlyProjectionAlertEnabled = defaults.bool(forKey: Key.projectionAlertEnabled)
        }
        if defaults.object(forKey: Key.projectionThreshold) != nil {
            prefs.monthlyProjectionThresholdUSD = defaults.double(forKey: Key.projectionThreshold)
        }
        if defaults.object(forKey: Key.projectionMinToday) != nil {
            prefs.monthlyProjectionMinTodayUSD = defaults.double(forKey: Key.projectionMinToday)
        }
        if defaults.object(forKey: Key.launchAtLoginEnabled) != nil {
            prefs.launchAtLoginEnabled = defaults.bool(forKey: Key.launchAtLoginEnabled)
        }
        return prefs
    }

    static func save(_ prefs: Preferences) {
        defaults.set(prefs.defaultMode.rawValue, forKey: Key.defaultMode)
        defaults.set(prefs.notificationCooldownSeconds, forKey: Key.notificationCooldown)
        defaults.set(prefs.oauthRefreshMinutes, forKey: Key.oauthRefreshMinutes)
        defaults.set(prefs.toastPeakAlertEnabled, forKey: Key.toastPeakAlertEnabled)
        defaults.set(prefs.toastPeakMinimumUSDPerHour, forKey: Key.toastPeakMinimum)
        defaults.set(prefs.monthlyProjectionAlertEnabled, forKey: Key.projectionAlertEnabled)
        defaults.set(prefs.monthlyProjectionThresholdUSD, forKey: Key.projectionThreshold)
        defaults.set(prefs.monthlyProjectionMinTodayUSD, forKey: Key.projectionMinToday)
        defaults.set(prefs.launchAtLoginEnabled, forKey: Key.launchAtLoginEnabled)
    }
}

enum SecretsAccount {
    static let claudeOAuth = "claude_oauth_token"
    static let anthropicAdmin = "anthropic_admin_api_key"
    /// JSON envelope for Ouroburn's own PKCE-managed Claude OAuth credential
    /// (`{accessToken, refreshToken, expiresAt}`). Owned by `OAuthCredentialStore`.
    static let ouroburnOAuth = "ouroburn_oauth_credential"
}

import Foundation

/// User-tunable settings. Non-secret values land in `UserDefaults`; tokens go to the keychain
/// (see `Keychain`). Anything tracked here can be edited from the settings window.
struct Preferences: Sendable {
    var spikeMultiplier: Double
    var spikeMinimumRate: Double
    var defaultMode: ViewMode
    var notificationCooldownSeconds: Double

    static let `default` = Preferences(
        spikeMultiplier: 2.0,
        spikeMinimumRate: 500,
        defaultMode: .day,
        notificationCooldownSeconds: 600
    )
}

@MainActor
enum PreferencesStore {
    private static let defaults = UserDefaults.standard
    private enum Key {
        static let spikeMultiplier = "ouroburn.spikeMultiplier"
        static let spikeMinimumRate = "ouroburn.spikeMinimumRate"
        static let defaultMode = "ouroburn.defaultMode"
        static let notificationCooldown = "ouroburn.notificationCooldown"
    }

    static func load() -> Preferences {
        var prefs = Preferences.default
        if defaults.object(forKey: Key.spikeMultiplier) != nil {
            prefs.spikeMultiplier = defaults.double(forKey: Key.spikeMultiplier)
        }
        if defaults.object(forKey: Key.spikeMinimumRate) != nil {
            prefs.spikeMinimumRate = defaults.double(forKey: Key.spikeMinimumRate)
        }
        if let raw = defaults.string(forKey: Key.defaultMode),
           let mode = ViewMode(rawValue: raw) {
            prefs.defaultMode = mode
        }
        if defaults.object(forKey: Key.notificationCooldown) != nil {
            prefs.notificationCooldownSeconds = defaults.double(forKey: Key.notificationCooldown)
        }
        return prefs
    }

    static func save(_ prefs: Preferences) {
        defaults.set(prefs.spikeMultiplier, forKey: Key.spikeMultiplier)
        defaults.set(prefs.spikeMinimumRate, forKey: Key.spikeMinimumRate)
        defaults.set(prefs.defaultMode.rawValue, forKey: Key.defaultMode)
        defaults.set(prefs.notificationCooldownSeconds, forKey: Key.notificationCooldown)
    }
}

enum SecretsAccount {
    static let claudeOAuth = "claude_oauth_token"
    static let anthropicAdmin = "anthropic_admin_api_key"
}

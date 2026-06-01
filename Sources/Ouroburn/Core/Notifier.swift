import Foundation
import UserNotifications

/// Throttled spike notifications. Asks for authorization once on launch and then drops repeats
/// until the cooldown has elapsed, so a long burst doesn't carpet-bomb the user.
@MainActor
final class Notifier {
    private let center: UNUserNotificationCenter
    private let cooldown: TimeInterval
    private var authorized = false
    private var lastDelivered: Date?

    init(center: UNUserNotificationCenter = .current(), cooldown: TimeInterval = 10 * 60) {
        self.center = center
        self.cooldown = max(60, cooldown) // floor: don't allow accidental every-second spam
    }

    func requestAuthorization() {
        center.requestAuthorization(options: [.alert, .sound]) { [weak self] granted, _ in
            Task { @MainActor [weak self] in
                self?.authorized = granted
            }
        }
    }

    func deliverSpike(currentRate: Double, previousRate: Double, todayCostUSD: Double) {
        guard authorized else { return }
        if let last = lastDelivered, Date().timeIntervalSince(last) < cooldown { return }

        let content = UNMutableNotificationContent()
        content.title = "ouroburn — burn rate spike"
        let now = NumberFormatting.compactRate(tokensPerMinute: currentRate)
        let was = NumberFormatting.compactRate(tokensPerMinute: previousRate)
        let today = NumberFormatting.compactDollars(todayCostUSD)
        content.body = "Now \(now) (was \(was)). \(today) spent today."
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "ouroburn.spike.\(Date().timeIntervalSince1970)",
            content: content,
            trigger: nil
        )
        center.add(request)
        lastDelivered = Date()
    }
}

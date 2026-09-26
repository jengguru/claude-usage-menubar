import Foundation
import UserNotifications
import HeadroomCore

final class NotificationManager: NSObject, UNUserNotificationCenterDelegate {
    /// `UNUserNotificationCenter` crashes outside an app bundle (e.g. `swift run`),
    /// so notifications are disabled there.
    private let center: UNUserNotificationCenter? =
        Bundle.main.bundleIdentifier == nil ? nil : UNUserNotificationCenter.current()

    override init() {
        super.init()
        center?.delegate = self
    }

    var isAvailable: Bool { center != nil }

    func requestAuthorization() {
        center?.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// `accountLabel` names the account only when it differs from the
    /// provider's own name — i.e. when it's worth disambiguating.
    func post(_ alert: ThresholdAlert, accountID: String = "", accountLabel: String? = nil) {
        let content = UNMutableNotificationContent()
        let name = (accountLabel != nil && accountLabel != alert.provider.displayName)
            ? "\(alert.provider.displayName) (\(accountLabel!))" : alert.provider.displayName
        content.title = "\(name) \(alert.windowName) usage at \(UsageFormatting.percent(alert.utilization))%"
        var body = "\(UsageFormatting.percent(max(100 - alert.utilization, 0)))% left"
        if let resetsAt = alert.resetsAt {
            body += " · resets in \(UsageFormatting.countdown(to: resetsAt)) (\(UsageFormatting.resetDescription(resetsAt)))"
        }
        content.body = body
        content.sound = alert.threshold >= 90 ? .defaultCritical : .default
        deliver(content, id: "threshold-\(alert.provider.rawValue)-\(accountID)-\(alert.windowID)")
    }

    func postTest() {
        let content = UNMutableNotificationContent()
        content.title = "Headroom notifications are on"
        content.body = "You'll be alerted when usage crosses your thresholds."
        content.sound = .default
        deliver(content, id: "test")
    }

    private func deliver(_ content: UNNotificationContent, id: String) {
        center?.add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }

    // Show banners even though a menu bar app is always "active".
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}

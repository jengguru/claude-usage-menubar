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

    func post(_ alert: ThresholdAlert) {
        let content = UNMutableNotificationContent()
        content.title = "Claude \(alert.kind.shortName) usage at \(UsageFormatting.percent(alert.utilization))%"
        var body = "\(UsageFormatting.percent(max(100 - alert.utilization, 0)))% left"
        if let resetsAt = alert.resetsAt {
            body += " · resets in \(UsageFormatting.countdown(to: resetsAt)) (\(UsageFormatting.resetDescription(resetsAt)))"
        }
        content.body = body
        content.sound = alert.threshold >= 90 ? .defaultCritical : .default
        deliver(content, id: "threshold-\(alert.kind.rawValue)")
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

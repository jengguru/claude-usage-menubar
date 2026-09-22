import Foundation
import ClaudeMeterCore

enum SettingsKey {
    static let refreshMinutes = "refreshMinutes"
    static let notificationsEnabled = "notificationsEnabled"
    static let sessionThresholds = "sessionThresholds"
    static let weeklyThresholds = "weeklyThresholds"
    static let menuBarText = "menuBarText"
    static let thresholdState = "thresholdState"
}

enum MenuBarTextMode: String, CaseIterable, Identifiable {
    case none, sessionUsed, sessionRemaining

    var id: String { rawValue }

    var label: String {
        switch self {
        case .none: return "Icon only"
        case .sessionUsed: return "Session % used"
        case .sessionRemaining: return "Session % left"
        }
    }
}

enum AppSettings {
    static let refreshChoices = [2, 5, 10, 15, 30]

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            SettingsKey.refreshMinutes: 5,
            SettingsKey.notificationsEnabled: true,
            SettingsKey.sessionThresholds: "75, 90",
            SettingsKey.weeklyThresholds: "75, 90",
            SettingsKey.menuBarText: MenuBarTextMode.sessionUsed.rawValue,
        ])
    }

    static var refreshInterval: TimeInterval {
        TimeInterval(max(UserDefaults.standard.integer(forKey: SettingsKey.refreshMinutes), 1) * 60)
    }

    static var notificationsEnabled: Bool {
        UserDefaults.standard.bool(forKey: SettingsKey.notificationsEnabled)
    }

    static var thresholds: [UsageWindowKind: [Int]] {
        let defaults = UserDefaults.standard
        let session = ThresholdParser.parse(defaults.string(forKey: SettingsKey.sessionThresholds) ?? "")
        let weekly = ThresholdParser.parse(defaults.string(forKey: SettingsKey.weeklyThresholds) ?? "")
        return [.session: session, .weekly: weekly, .weeklyOpus: weekly, .weeklySonnet: weekly]
    }

    static var thresholdState: ThresholdState {
        get {
            guard let data = UserDefaults.standard.data(forKey: SettingsKey.thresholdState),
                  let state = try? JSONDecoder().decode(ThresholdState.self, from: data) else { return ThresholdState() }
            return state
        }
        set {
            UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: SettingsKey.thresholdState)
        }
    }
}

import Foundation
import HeadroomCore

enum SettingsKey {
    static let refreshMinutes = "refreshMinutes"
    static let notificationsEnabled = "notificationsEnabled"
    static let sessionThresholds = "sessionThresholds"
    static let weeklyThresholds = "weeklyThresholds"
    static let menuBarText = "menuBarText"
    static let menuBarStyle = "menuBarStyle"

    static func providerEnabled(_ provider: UsageProvider) -> String {
        "providerEnabled.\(provider.rawValue)"
    }

    /// Claude keeps the pre-provider key so already-fired alerts carry over.
    static func thresholdState(_ provider: UsageProvider) -> String {
        provider == .claude ? "thresholdState" : "thresholdState.\(provider.rawValue)"
    }
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

enum MenuBarStyle: String, CaseIterable, Identifiable {
    /// One icon for the provider closest to a limit; every provider in its popover.
    case combined
    /// One icon and popover per provider.
    case separate

    var id: String { rawValue }

    var label: String {
        switch self {
        case .combined: return "One combined icon"
        case .separate: return "One icon per service"
        }
    }
}

enum AppSettings {
    static let refreshChoices = [2, 5, 10, 15, 30]

    static func registerDefaults() {
        var defaults: [String: Any] = [
            SettingsKey.refreshMinutes: 5,
            SettingsKey.notificationsEnabled: true,
            SettingsKey.sessionThresholds: "75, 90",
            SettingsKey.weeklyThresholds: "75, 90",
            SettingsKey.menuBarText: MenuBarTextMode.sessionUsed.rawValue,
            SettingsKey.menuBarStyle: MenuBarStyle.combined.rawValue,
        ]
        for provider in UsageProvider.allCases {
            defaults[SettingsKey.providerEnabled(provider)] = true
        }
        UserDefaults.standard.register(defaults: defaults)
    }

    static var refreshInterval: TimeInterval {
        TimeInterval(max(UserDefaults.standard.integer(forKey: SettingsKey.refreshMinutes), 1) * 60)
    }

    static var notificationsEnabled: Bool {
        UserDefaults.standard.bool(forKey: SettingsKey.notificationsEnabled)
    }

    static func isEnabled(_ provider: UsageProvider) -> Bool {
        UserDefaults.standard.bool(forKey: SettingsKey.providerEnabled(provider))
    }

    /// Shared by all providers: short windows use the session thresholds, multi-day ones the weekly.
    static var thresholds: [UsageWindowCategory: [Int]] {
        let defaults = UserDefaults.standard
        return [
            .session: ThresholdParser.parse(defaults.string(forKey: SettingsKey.sessionThresholds) ?? ""),
            .weekly: ThresholdParser.parse(defaults.string(forKey: SettingsKey.weeklyThresholds) ?? ""),
        ]
    }

    static func thresholdState(for provider: UsageProvider) -> ThresholdState {
        guard let data = UserDefaults.standard.data(forKey: SettingsKey.thresholdState(provider)),
              let state = try? JSONDecoder().decode(ThresholdState.self, from: data) else { return ThresholdState() }
        return state
    }

    static func setThresholdState(_ state: ThresholdState, for provider: UsageProvider) {
        UserDefaults.standard.set(try? JSONEncoder().encode(state), forKey: SettingsKey.thresholdState(provider))
    }
}

import Foundation

public struct ThresholdAlert: Equatable, Sendable {
    public let provider: UsageProvider
    public let windowID: String
    /// "session", "weekly Opus": completes "<Provider> <name> usage at 90%".
    public let windowName: String
    public let threshold: Int
    public let utilization: Double
    public let resetsAt: Date?
}

/// Which thresholds have already fired, per window of one provider. Persisted
/// so relaunching the app doesn't repeat notifications.
public struct ThresholdState: Codable, Equatable, Sendable {
    public var fired: [String: [Int]] = [:]
    public var anchors: [String: Date] = [:]

    public init() {}
}

public struct ThresholdEvaluator: Sendable {
    /// A fired threshold re-arms once usage drops this many points below it.
    public var hysteresis: Double = 5
    /// A reset time moving by more than this means a new window has started.
    public var windowChangeTolerance: TimeInterval = 30 * 60

    public init() {}

    /// Returns at most one alert per window: the highest threshold newly
    /// crossed since the last evaluation.
    public func evaluate(
        snapshot: UsageSnapshot,
        thresholds: [UsageWindowCategory: [Int]],
        state: inout ThresholdState
    ) -> [ThresholdAlert] {
        var alerts: [ThresholdAlert] = []
        for window in snapshot.windows {
            guard let levels = thresholds[window.category], !levels.isEmpty else { continue }
            let key = window.id
            var fired = Set(state.fired[key] ?? [])

            if let resetsAt = window.resetsAt {
                if let anchor = state.anchors[key], abs(resetsAt.timeIntervalSince(anchor)) > windowChangeTolerance {
                    fired.removeAll()
                }
                state.anchors[key] = resetsAt
            }
            fired = fired.filter { Double($0) - hysteresis <= window.utilization }

            let crossed = Set(levels.filter { Double($0) <= window.utilization })
            if let highest = crossed.subtracting(fired).max() {
                alerts.append(ThresholdAlert(provider: snapshot.provider, windowID: window.id, windowName: window.shortName,
                                             threshold: highest, utilization: window.utilization, resetsAt: window.resetsAt))
            }
            state.fired[key] = fired.union(crossed).sorted()
        }
        return alerts
    }
}

public enum ThresholdParser {
    /// "75, 90" → [75, 90]. Ignores junk, clamps to 1…100, dedupes and sorts.
    public static func parse(_ text: String) -> [Int] {
        let values = text
            .split(whereSeparator: { $0 == "," || $0 == " " || $0 == ";" || $0 == "%" })
            .compactMap { Int($0) }
            .filter { (1...100).contains($0) }
        return Array(Set(values)).sorted()
    }

    public static func format(_ values: [Int]) -> String {
        values.map(String.init).joined(separator: ", ")
    }
}

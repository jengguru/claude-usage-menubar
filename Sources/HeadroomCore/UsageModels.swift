import Foundation

/// The usage windows reported by the Claude OAuth usage endpoint.
public enum UsageWindowKind: String, Codable, CaseIterable, Sendable {
    case session        // five_hour
    case weekly         // seven_day
    case weeklyOpus     // seven_day_opus
    case weeklySonnet   // seven_day_sonnet

    /// Key in the JSON returned by `/api/oauth/usage`.
    public var apiKey: String {
        switch self {
        case .session: return "five_hour"
        case .weekly: return "seven_day"
        case .weeklyOpus: return "seven_day_opus"
        case .weeklySonnet: return "seven_day_sonnet"
        }
    }

    public var title: String {
        switch self {
        case .session: return "Current Session"
        case .weekly: return "Weekly Limit"
        case .weeklyOpus: return "Weekly · Opus"
        case .weeklySonnet: return "Weekly · Sonnet"
        }
    }

    /// Short name used in notifications ("Claude session usage at 90%").
    public var shortName: String {
        switch self {
        case .session: return "session"
        case .weekly: return "weekly"
        case .weeklyOpus: return "weekly Opus"
        case .weeklySonnet: return "weekly Sonnet"
        }
    }

    /// Windows that are always shown, even when the API reports `null` (no usage yet).
    public var isPrimary: Bool { self == .session || self == .weekly }
}

public struct UsageWindow: Equatable, Sendable {
    public let kind: UsageWindowKind
    /// Percentage of the limit used, 0–100 (can exceed 100 when over the limit).
    public let utilization: Double
    /// When this window resets. `nil` when the window has not started yet.
    public let resetsAt: Date?

    public init(kind: UsageWindowKind, utilization: Double, resetsAt: Date?) {
        self.kind = kind
        self.utilization = utilization
        self.resetsAt = resetsAt
    }

    public var usedPercent: Double { min(max(utilization, 0), 100) }
    public var remainingPercent: Double { 100 - usedPercent }
    public var fraction: Double { usedPercent / 100 }
}

public struct UsageSnapshot: Equatable, Sendable {
    public let windows: [UsageWindow]
    public let fetchedAt: Date

    public init(windows: [UsageWindow], fetchedAt: Date) {
        self.windows = windows
        self.fetchedAt = fetchedAt
    }

    public func window(_ kind: UsageWindowKind) -> UsageWindow? {
        windows.first { $0.kind == kind }
    }

    public var session: UsageWindow? { window(.session) }
    public var weekly: UsageWindow? { window(.weekly) }
    /// Model-specific weekly windows, present only on some plans.
    public var extraWindows: [UsageWindow] { windows.filter { !$0.kind.isPrimary } }
}

public enum UsageDecodingError: Error, LocalizedError, Equatable {
    case unexpectedFormat(String)

    public var errorDescription: String? {
        switch self {
        case .unexpectedFormat(let snippet):
            return "Unexpected response from the usage endpoint: \(snippet)"
        }
    }
}

public enum UsageDecoder {
    /// Decodes the `/api/oauth/usage` response. Parsing is deliberately lenient:
    /// the endpoint is undocumented, so unknown keys are ignored and missing
    /// optional windows are skipped.
    ///
    ///     {"five_hour": {"utilization": 59.0, "resets_at": "2026-09-22T16:00:00.123456+00:00"},
    ///      "seven_day": {"utilization": 73.0, "resets_at": "..."},
    ///      "seven_day_opus": null, ...}
    public static func decode(_ data: Data, fetchedAt: Date = Date()) throws -> UsageSnapshot {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              root.keys.contains(UsageWindowKind.session.apiKey)
                || root.keys.contains(UsageWindowKind.weekly.apiKey)
        else {
            throw UsageDecodingError.unexpectedFormat(snippet(data))
        }

        var windows: [UsageWindow] = []
        for kind in UsageWindowKind.allCases {
            guard let raw = root[kind.apiKey] else { continue }
            if let object = raw as? [String: Any], let utilization = number(object["utilization"]) {
                windows.append(UsageWindow(kind: kind, utilization: utilization, resetsAt: date(object["resets_at"])))
            } else if kind.isPrimary {
                // `null` means the window hasn't started: nothing used yet.
                windows.append(UsageWindow(kind: kind, utilization: 0, resetsAt: nil))
            }
        }
        return UsageSnapshot(windows: windows, fetchedAt: fetchedAt)
    }

    static func number(_ value: Any?) -> Double? {
        switch value {
        case let d as Double: return d
        case let i as Int: return Double(i)
        case let n as NSNumber: return n.doubleValue
        case let s as String: return Double(s)
        default: return nil
        }
    }

    static func date(_ value: Any?) -> Date? {
        if let string = value as? String { return parseISO8601(string) }
        if let seconds = number(value) { return Date(timeIntervalSince1970: seconds > 1e12 ? seconds / 1000 : seconds) }
        return nil
    }

    /// Parses ISO 8601 timestamps with any number of fractional-second digits
    /// (the API sends microseconds, which `ISO8601DateFormatter` rejects).
    public static func parseISO8601(_ string: String) -> Date? {
        var base = string
        var fraction = 0.0
        if let tIndex = string.firstIndex(of: "T"), let dot = string[tIndex...].firstIndex(of: ".") {
            let digitsStart = string.index(after: dot)
            let digitsEnd = string[digitsStart...].firstIndex { !$0.isNumber } ?? string.endIndex
            fraction = Double("0." + string[digitsStart..<digitsEnd]) ?? 0
            base = String(string[..<dot]) + String(string[digitsEnd...])
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: base)?.addingTimeInterval(fraction)
    }

    private static func snippet(_ data: Data) -> String {
        let text = String(decoding: data.prefix(200), as: UTF8.self)
        return text.isEmpty ? "<empty body>" : text
    }
}

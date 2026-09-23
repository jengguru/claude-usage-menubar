import Foundation

/// A service whose subscription usage limits Headroom shows.
public enum UsageProvider: String, Codable, CaseIterable, Identifiable, Sendable {
    case claude
    case codex

    public var id: String { rawValue }

    /// "Claude", "Codex". Used in the UI and in notification titles.
    public var displayName: String {
        switch self {
        case .claude: return "Claude"
        case .codex: return "Codex"
        }
    }

    /// Who runs the usage endpoint ("Rate limited by OpenAI").
    public var vendor: String {
        switch self {
        case .claude: return "Anthropic"
        case .codex: return "OpenAI"
        }
    }
}

/// Which threshold setting applies to a window: short rolling windows use the
/// "session" thresholds, multi-day windows the "weekly" ones.
public enum UsageWindowCategory: String, Codable, CaseIterable, Sendable {
    case session
    case weekly

    /// Windows up to a day long count as sessions.
    public init(duration: TimeInterval) {
        self = duration <= 86_400 ? .session : .weekly
    }
}

public struct UsageWindow: Equatable, Sendable {
    /// Stable within a provider; keys persisted threshold state.
    public let id: String
    /// "Current Session", "Weekly Limit".
    public let title: String
    /// Used in notifications: "Codex weekly usage at 90%".
    public let shortName: String
    public let category: UsageWindowCategory
    /// Primary windows (session + weekly) get the large cards; others are compact rows.
    public let isPrimary: Bool
    /// Percentage of the limit used, 0–100 (can exceed 100 when over the limit).
    public let utilization: Double
    /// When this window resets. `nil` when the window has not started yet.
    public let resetsAt: Date?

    public init(
        id: String,
        title: String,
        shortName: String,
        category: UsageWindowCategory,
        isPrimary: Bool,
        utilization: Double,
        resetsAt: Date?
    ) {
        self.id = id
        self.title = title
        self.shortName = shortName
        self.category = category
        self.isPrimary = isPrimary
        self.utilization = utilization
        self.resetsAt = resetsAt
    }

    public var usedPercent: Double { min(max(utilization, 0), 100) }
    public var remainingPercent: Double { 100 - usedPercent }
    public var fraction: Double { usedPercent / 100 }
}

public struct UsageSnapshot: Equatable, Sendable {
    public let provider: UsageProvider
    public let windows: [UsageWindow]
    /// Subscription plan as reported by the provider ("max", "plus"). Informational only.
    public let plan: String?
    public let fetchedAt: Date

    public init(provider: UsageProvider, windows: [UsageWindow], plan: String? = nil, fetchedAt: Date) {
        self.provider = provider
        self.windows = windows
        self.plan = plan
        self.fetchedAt = fetchedAt
    }

    public func window(id: String) -> UsageWindow? {
        windows.first { $0.id == id }
    }

    /// The primary short window (Claude's 5-hour session, Codex's 5h limit).
    public var session: UsageWindow? { windows.first { $0.isPrimary && $0.category == .session } }
    /// The primary weekly window.
    public var weekly: UsageWindow? { windows.first { $0.isPrimary && $0.category == .weekly } }
    /// Model- or feature-specific windows, present only on some plans.
    public var extraWindows: [UsageWindow] { windows.filter { !$0.isPrimary } }

    /// How close this provider is to a limit that blocks it outright: the highest
    /// primary window. Model-specific windows are left out because hitting one
    /// still leaves the other models available.
    public var peakUtilization: Double? {
        windows.filter(\.isPrimary).map(\.utilization).max()
    }
}

extension Sequence where Element == UsageSnapshot {
    /// The snapshot closest to its limit. Ties go to the earlier element, so the
    /// menu bar doesn't flip between providers at equal usage.
    public func mostConstrained() -> UsageSnapshot? {
        var best: UsageSnapshot?
        for snapshot in self {
            guard let peak = snapshot.peakUtilization else { continue }
            if let current = best?.peakUtilization, current >= peak { continue }
            best = snapshot
        }
        return best
    }
}

public enum UsageDecodingError: Error, LocalizedError, Equatable {
    case unexpectedFormat(provider: UsageProvider, snippet: String)

    public var errorDescription: String? {
        switch self {
        case .unexpectedFormat(let provider, let snippet):
            return "Unexpected response from the \(provider.displayName) usage endpoint: \(snippet)"
        }
    }
}

/// Lenient JSON value helpers shared by the provider decoders.
public enum JSONValue {
    public static func number(_ value: Any?) -> Double? {
        switch value {
        case let d as Double: return d
        case let i as Int: return Double(i)
        case let n as NSNumber: return n.doubleValue
        case let s as String: return Double(s)
        default: return nil
        }
    }

    /// ISO 8601 strings, or epoch seconds/milliseconds.
    public static func date(_ value: Any?) -> Date? {
        if let string = value as? String, let date = parseISO8601(string) { return date }
        if let seconds = number(value) { return Date(timeIntervalSince1970: seconds > 1e12 ? seconds / 1000 : seconds) }
        return nil
    }

    /// Parses ISO 8601 timestamps with any number of fractional-second digits
    /// (Anthropic sends microseconds, which `ISO8601DateFormatter` rejects).
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

    /// The start of a response body, for error messages. Usage responses carry
    /// no secrets (the token is only in the request).
    public static func snippet(_ data: Data) -> String {
        let text = String(decoding: data.prefix(200), as: UTF8.self)
        return text.isEmpty ? "<empty body>" : text
    }
}

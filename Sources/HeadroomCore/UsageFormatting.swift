import Foundation

public enum UsageLevel: Sendable {
    case normal, warning, critical

    public init(utilization: Double) {
        switch utilization {
        case ..<70: self = .normal
        case ..<90: self = .warning
        default: self = .critical
        }
    }
}

public enum UsageFormatting {
    /// "59" — whole percent, rounded, clamped at 0.
    public static func percent(_ value: Double) -> String {
        String(Int(max(value, 0).rounded()))
    }

    /// Time until `date`: "2d 4h", "3h 27m", "12m", "<1m", or "now".
    public static func countdown(to date: Date, now: Date = Date()) -> String {
        let seconds = date.timeIntervalSince(now)
        guard seconds > 0 else { return "now" }
        let minutes = Int(seconds / 60)
        let days = minutes / 1440
        let hours = (minutes % 1440) / 60
        let mins = minutes % 60
        if days > 0 { return "\(days)d \(hours)h" }
        if hours > 0 { return "\(hours)h \(mins)m" }
        if mins > 0 { return "\(mins)m" }
        return "<1m"
    }

    /// "Today at 16:00", "Tomorrow at 09:00", "Wed at 15:00", or "Oct 3 at 15:00".
    public static func resetDescription(
        _ date: Date,
        now: Date = Date(),
        calendar: Calendar = .current,
        locale: Locale = .current
    ) -> String {
        let time = formatter(template: "jmm", calendar: calendar, locale: locale).string(from: date)
        let day: String
        if calendar.isDate(date, inSameDayAs: now) {
            day = "Today"
        } else if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now),
                  calendar.isDate(date, inSameDayAs: tomorrow) {
            day = "Tomorrow"
        } else if date > now, date.timeIntervalSince(now) < 6 * 86_400 {
            day = formatter(template: "EEE", calendar: calendar, locale: locale).string(from: date)
        } else {
            day = formatter(template: "MMMd", calendar: calendar, locale: locale).string(from: date)
        }
        return "\(day) at \(time)"
    }

    /// "just now", "3m ago", "2h ago".
    public static func relativeAge(of date: Date, now: Date = Date()) -> String {
        let seconds = now.timeIntervalSince(date)
        if seconds < 60 { return "just now" }
        let minutes = Int(seconds / 60)
        if minutes < 60 { return "\(minutes)m ago" }
        return "\(minutes / 60)h ago"
    }

    private static func formatter(template: String, calendar: Calendar, locale: Locale) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = locale
        formatter.setLocalizedDateFormatFromTemplate(template)
        return formatter
    }
}

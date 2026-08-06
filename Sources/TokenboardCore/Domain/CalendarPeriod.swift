import Foundation

public enum CalendarPeriod: String, CaseIterable, Codable, Sendable {
    case today
    case thisWeek = "this_week"
    case thisMonth = "this_month"
    case thisYear = "this_year"
    case allTime = "all_time"

    public func interval(containing date: Date, calendar input: Calendar) -> DateInterval? {
        var calendar = input
        calendar.firstWeekday = 2
        switch self {
        case .today: return calendar.dateInterval(of: .day, for: date)
        case .thisWeek: return calendar.dateInterval(of: .weekOfYear, for: date)
        case .thisMonth: return calendar.dateInterval(of: .month, for: date)
        case .thisYear: return calendar.dateInterval(of: .year, for: date)
        case .allTime: return nil
        }
    }
}

public struct LocalDay: Hashable, Codable, Sendable {
    public let value: String
    public let timeZoneIdentifier: String

    public init(date: Date, calendar: Calendar) {
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.locale = Locale(identifier: "en_US_POSIX")
        gregorian.timeZone = calendar.timeZone
        let components = gregorian.dateComponents([.year, .month, .day], from: date)
        self.value = String(
            format: "%04d-%02d-%02d",
            locale: Locale(identifier: "en_US_POSIX"),
            components.year!,
            components.month!,
            components.day!
        )
        self.timeZoneIdentifier = calendar.timeZone.identifier
    }
}

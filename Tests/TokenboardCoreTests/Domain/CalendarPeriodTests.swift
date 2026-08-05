import Foundation
import XCTest
@testable import TokenboardCore

final class CalendarPeriodTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = TimeZone(identifier: "Europe/Amsterdam")!
        calendar.firstWeekday = 2
        return calendar
    }

    func testWeekBeginsMonday() throws {
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-08-05T12:00:00Z"))
        let interval = try XCTUnwrap(CalendarPeriod.thisWeek.interval(containing: now, calendar: calendar))
        XCTAssertEqual(calendar.component(.weekday, from: interval.start), 2)
    }

    func testAllTimeHasNoLowerBound() {
        XCTAssertNil(CalendarPeriod.allTime.interval(containing: Date(), calendar: calendar))
    }

    func testWeekBeginsMondayEvenWhenInputCalendarStartsOnSunday() throws {
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-08-05T12:00:00Z"))
        var sundayFirstCalendar = calendar
        sundayFirstCalendar.firstWeekday = 1

        let interval = try XCTUnwrap(CalendarPeriod.thisWeek.interval(containing: now, calendar: sundayFirstCalendar))
        XCTAssertEqual(calendar.component(.weekday, from: interval.start), 2)
    }

    func testLocalDayUsesTheCalendarTimeZoneAndLocalDate() throws {
        let date = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-08-05T22:30:00Z"))

        let localDay = LocalDay(date: date, calendar: calendar)

        XCTAssertEqual(localDay.value, "2026-08-06")
        XCTAssertEqual(localDay.timeZoneIdentifier, "Europe/Amsterdam")
    }
}

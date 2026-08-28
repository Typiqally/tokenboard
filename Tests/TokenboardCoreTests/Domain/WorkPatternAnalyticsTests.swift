import Foundation
import XCTest
@testable import TokenboardCore

final class WorkPatternAnalyticsTests: XCTestCase {
    func testCalculatesBalancedMetricsAndSeparatesVolumeFromConsistency() throws {
        let calendar = amsterdamCalendar()
        let current = interval("2026-08-02T22:00:00Z", "2026-08-16T22:00:00Z")
        let previous = interval("2026-07-19T22:00:00Z", "2026-08-02T22:00:00Z")
        let rows = [
            row("2026-08-03T07:00:00Z", quantity: 100),
            row("2026-08-03T08:00:00Z", quantity: 20),
            row("2026-08-04T13:00:00Z", quantity: 500),
            row("2026-08-05T07:00:00Z", quantity: 10),
            row("2026-08-10T07:00:00Z", quantity: 50),
        ]
        let previousRows = [
            row("2026-07-20T07:00:00Z", quantity: 20),
            row("2026-07-21T08:00:00Z", quantity: 30),
        ]

        let snapshot = try WorkPatternCalculator().make(
            currentRows: rows,
            previousRows: previousRows,
            currentInterval: current,
            previousInterval: previous,
            coverageStart: previous.start,
            now: current.end.addingTimeInterval(-1),
            calendar: calendar
        )

        XCTAssertFalse(snapshot.isCoveragePartial)
        XCTAssertEqual(snapshot.totalActiveHours, 5)
        XCTAssertEqual(snapshot.activeDayCount, 4)
        XCTAssertEqual(snapshot.averageActiveHoursPerActiveDay, Decimal(string: "1.25"))
        XCTAssertEqual(snapshot.averageActiveDaysPerWeek, 2)
        XCTAssertEqual(snapshot.volumePeakHour?.hour, 15)
        XCTAssertEqual(snapshot.volumePeakHour?.tokenTotal, 500)
        XCTAssertEqual(snapshot.consistentHour?.hour, 9)
        XCTAssertEqual(snapshot.consistentHour?.activeOccurrenceCount, 3)
        XCTAssertEqual(snapshot.consistentHour?.eligibleOccurrenceCount, 4)
        XCTAssertEqual(snapshot.volumePeakWeekday?.weekday, .tuesday)
        XCTAssertEqual(snapshot.consistentWeekday?.weekday, .monday)
        XCTAssertEqual(snapshot.typicalFirstActivityHour, 9)
        XCTAssertEqual(snapshot.typicalLastActivityHour, 10)
        XCTAssertEqual(snapshot.longestActiveRunHours, 2)
        XCTAssertEqual(snapshot.busiestDay?.localDay.value, "2026-08-04")
        XCTAssertEqual(snapshot.busiestDay?.tokenTotal, 500)
        XCTAssertEqual(snapshot.days.count, 14)
        XCTAssertEqual(snapshot.heatmap.count, 168)
        XCTAssertEqual(snapshot.comparison, WorkPatternComparison(
            currentActiveHours: 5,
            previousActiveHours: 2,
            activeHourDelta: 3,
            percentChange: 150
        ))
    }

    func testDeduplicatesAdditiveRowsAndExcludesInformationalSubsets() throws {
        let calendar = amsterdamCalendar()
        let current = interval("2026-08-02T22:00:00Z", "2026-08-09T22:00:00Z")
        let hour = date("2026-08-03T07:00:00Z")
        let rows = [
            row(hour, provider: .codex, metric: .inputUncached, quantity: 100),
            row(hour, provider: .claudeCode, metric: .output, quantity: 200),
            row("2026-08-03T08:00:00Z", metric: .detailReasoningOutput, quantity: 900),
        ]

        let snapshot = try WorkPatternCalculator().make(
            currentRows: rows,
            previousRows: [],
            currentInterval: current,
            previousInterval: interval("2026-07-26T22:00:00Z", "2026-08-02T22:00:00Z"),
            coverageStart: date("2026-07-01T00:00:00Z"),
            now: current.end.addingTimeInterval(-1),
            calendar: calendar
        )

        XCTAssertEqual(snapshot.totalActiveHours, 1)
        XCTAssertEqual(snapshot.activeDayCount, 1)
        XCTAssertEqual(snapshot.days.first(where: { $0.activeHourCount > 0 })?.tokenTotal, 300)
        XCTAssertEqual(snapshot.volumePeakHour?.hour, 9)
        XCTAssertEqual(snapshot.comparison, WorkPatternComparison(
            currentActiveHours: 1,
            previousActiveHours: 0,
            activeHourDelta: 1,
            percentChange: nil
        ))
    }

    func testPartialCoverageUsesOnlyCoveredCalendarDays() throws {
        let calendar = amsterdamCalendar()
        let current = interval("2026-08-02T22:00:00Z", "2026-08-16T22:00:00Z")
        let coverageStart = date("2026-08-10T07:35:00Z")

        let snapshot = try WorkPatternCalculator().make(
            currentRows: [row("2026-08-10T07:00:00Z", quantity: 10)],
            previousRows: [],
            currentInterval: current,
            previousInterval: interval("2026-07-19T22:00:00Z", "2026-08-02T22:00:00Z"),
            coverageStart: coverageStart,
            now: current.end.addingTimeInterval(-1),
            calendar: calendar
        )

        XCTAssertTrue(snapshot.isCoveragePartial)
        XCTAssertEqual(snapshot.coverageStart, calendar.dateInterval(of: .hour, for: coverageStart)?.start)
        XCTAssertEqual(snapshot.coveredCalendarDayCount, 7)
        XCTAssertEqual(snapshot.averageActiveDaysPerWeek, 1)
        XCTAssertNil(snapshot.comparison)
    }

    func testRepeatedDSTHourRemainsTwoActiveBucketsWithoutInflatingFrequency() throws {
        let calendar = amsterdamCalendar()
        let current = interval("2026-10-24T22:00:00Z", "2026-10-26T23:00:00Z")
        let rows = [
            row("2026-10-25T00:15:00Z", quantity: 10),
            row("2026-10-25T01:15:00Z", quantity: 20),
        ]

        let snapshot = try WorkPatternCalculator().make(
            currentRows: rows,
            previousRows: [],
            currentInterval: current,
            previousInterval: interval("2026-10-22T22:00:00Z", "2026-10-24T22:00:00Z"),
            coverageStart: current.start,
            now: current.end.addingTimeInterval(-1),
            calendar: calendar
        )

        XCTAssertEqual(snapshot.totalActiveHours, 2)
        XCTAssertEqual(snapshot.activeDayCount, 1)
        XCTAssertEqual(snapshot.volumePeakHour?.hour, 2)
        XCTAssertEqual(snapshot.volumePeakHour?.tokenTotal, 30)
        XCTAssertEqual(snapshot.consistentHour?.activeOccurrenceCount, 1)
        XCTAssertEqual(snapshot.longestActiveRunHours, 2)
    }

    private func row(
        _ value: String,
        provider: Provider = .codex,
        metric: UsageMetric = .inputUncached,
        quantity: Int64
    ) -> HourlyUsageRow {
        row(date(value), provider: provider, metric: metric, quantity: quantity)
    }

    private func row(
        _ timestamp: Date,
        provider: Provider = .codex,
        metric: UsageMetric = .inputUncached,
        quantity: Int64
    ) -> HourlyUsageRow {
        HourlyUsageRow(
            hourStart: timestamp,
            localDay: LocalDay(date: timestamp, calendar: amsterdamCalendar()),
            provider: provider,
            observedModelID: "synthetic-model",
            metric: metric,
            aggregation: metric.aggregation,
            quantity: quantity
        )
    }

    private func date(_ value: String) -> Date {
        ISO8601DateFormatter().date(from: value)!
    }

    private func interval(_ start: String, _ end: String) -> DateInterval {
        DateInterval(start: date(start), end: date(end))
    }

    private func amsterdamCalendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = TimeZone(identifier: "Europe/Amsterdam")!
        calendar.firstWeekday = 2
        return calendar
    }
}

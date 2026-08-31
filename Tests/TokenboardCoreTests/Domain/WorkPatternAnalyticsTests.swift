import Foundation
import XCTest
@testable import TokenboardCore

final class WorkPatternAnalyticsTests: XCTestCase {
    func testCalculatesFocusTimeSessionsAndSeparatesVolumeFromConsistency() throws {
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
        let activity = [
            slice("2026-08-03T07:00:00Z"),
            slice("2026-08-03T07:10:00Z"),
            slice("2026-08-03T08:00:00Z"),
            slice("2026-08-04T13:00:00Z"),
            slice("2026-08-05T07:00:00Z"),
            slice("2026-08-10T07:00:00Z"),
        ]
        let previousActivity = [
            slice("2026-07-20T07:00:00Z"),
            slice("2026-07-21T08:00:00Z"),
        ]

        let snapshot = try WorkPatternCalculator().make(
            currentRows: rows,
            currentActivity: activity,
            previousActivity: previousActivity,
            currentInterval: current,
            previousInterval: previous,
            coverageStart: previous.start,
            now: current.end.addingTimeInterval(-1),
            calendar: calendar
        )

        XCTAssertFalse(snapshot.isCoveragePartial)
        XCTAssertEqual(snapshot.totalFocusMinutes, 35)
        XCTAssertEqual(snapshot.focusSessionCount, 5)
        XCTAssertEqual(snapshot.activeDayCount, 4)
        XCTAssertEqual(snapshot.averageFocusMinutesPerActiveDay, Decimal(string: "8.75"))
        XCTAssertEqual(snapshot.averageFocusSessionMinutes, 7)
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
        XCTAssertEqual(snapshot.longestFocusSessionMinutes, 15)
        XCTAssertEqual(snapshot.busiestDay?.localDay.value, "2026-08-04")
        XCTAssertEqual(snapshot.busiestDay?.tokenTotal, 500)
        XCTAssertEqual(snapshot.days.count, 14)
        XCTAssertEqual(snapshot.heatmap.count, 168)
        XCTAssertEqual(snapshot.comparison, WorkPatternComparison(
            currentFocusMinutes: 35,
            previousFocusMinutes: 10,
            focusMinuteDelta: 25,
            percentChange: 250
        ))
    }

    func testIsolatedUsageCountsAsFiveMinutesInsteadOfAWholeHour() throws {
        let calendar = amsterdamCalendar()
        let current = interval("2026-08-02T22:00:00Z", "2026-08-09T22:00:00Z")

        let snapshot = try WorkPatternCalculator().make(
            currentRows: [row("2026-08-03T07:00:00Z", quantity: 300)],
            currentActivity: [slice("2026-08-03T07:01:00Z")],
            previousActivity: [],
            currentInterval: current,
            previousInterval: interval("2026-07-26T22:00:00Z", "2026-08-02T22:00:00Z"),
            coverageStart: date("2026-07-01T00:00:00Z"),
            now: current.end.addingTimeInterval(-1),
            calendar: calendar
        )

        XCTAssertEqual(snapshot.totalFocusMinutes, 5)
        XCTAssertEqual(snapshot.focusSessionCount, 1)
        XCTAssertEqual(snapshot.longestFocusSessionMinutes, 5)
        XCTAssertEqual(snapshot.days.first(where: { $0.focusMinuteCount > 0 })?.focusMinuteCount, 5)
    }

    func testNearbySlicesFormOneBlockWhileAnIdleGapStartsAnother() throws {
        let calendar = amsterdamCalendar()
        let current = interval("2026-08-02T22:00:00Z", "2026-08-09T22:00:00Z")
        let activity = [
            slice("2026-08-03T07:01:00Z"),
            slice("2026-08-03T07:11:00Z"),
            slice("2026-08-03T07:31:00Z"),
        ]

        let snapshot = try WorkPatternCalculator().make(
            currentRows: [row("2026-08-03T07:00:00Z", quantity: 300)],
            currentActivity: activity,
            previousActivity: [],
            currentInterval: current,
            previousInterval: interval("2026-07-26T22:00:00Z", "2026-08-02T22:00:00Z"),
            coverageStart: date("2026-07-01T00:00:00Z"),
            now: current.end.addingTimeInterval(-1),
            calendar: calendar
        )

        XCTAssertEqual(snapshot.totalFocusMinutes, 20)
        XCTAssertEqual(snapshot.focusSessionCount, 2)
        XCTAssertEqual(snapshot.averageFocusSessionMinutes, 10)
        XCTAssertEqual(snapshot.longestFocusSessionMinutes, 15)
    }

    func testOverlappingProvidersDoNotDoubleCountTheSameActivitySlice() throws {
        let calendar = amsterdamCalendar()
        let current = interval("2026-08-02T22:00:00Z", "2026-08-09T22:00:00Z")
        let timestamp = "2026-08-03T07:00:00Z"

        let snapshot = try WorkPatternCalculator().make(
            currentRows: [row(timestamp, quantity: 300)],
            currentActivity: [
                slice(timestamp, provider: .codex),
                slice(timestamp, provider: .claudeCode),
            ],
            previousActivity: [],
            currentInterval: current,
            previousInterval: interval("2026-07-26T22:00:00Z", "2026-08-02T22:00:00Z"),
            coverageStart: date("2026-07-01T00:00:00Z"),
            now: current.end.addingTimeInterval(-1),
            calendar: calendar
        )

        XCTAssertEqual(snapshot.totalFocusMinutes, 5)
        XCTAssertEqual(snapshot.focusSessionCount, 1)
    }

    func testDerivesEstimateCompositionBlockProfileToolMixAndCadence() throws {
        let calendar = amsterdamCalendar()
        let current = interval("2026-08-02T22:00:00Z", "2026-08-09T22:00:00Z")
        let activity = [
            slice("2026-08-03T06:00:00Z", provider: .codex),
            slice("2026-08-03T07:00:00Z", provider: .claudeCode),
            slice("2026-08-03T07:10:00Z", provider: .claudeCode),
            slice("2026-08-03T08:00:00Z", provider: .codex),
            slice("2026-08-03T08:15:00Z", provider: .claudeCode),
            slice("2026-08-03T08:25:00Z", provider: .codex),
            slice("2026-08-03T10:00:00Z", provider: .codex),
            slice("2026-08-03T10:15:00Z", provider: .codex),
            slice("2026-08-03T10:30:00Z", provider: .codex),
            slice("2026-08-03T10:45:00Z", provider: .codex),
            slice("2026-08-03T10:55:00Z", provider: .codex),
        ]

        let snapshot = try WorkPatternCalculator().make(
            currentRows: [],
            currentActivity: activity,
            previousActivity: [],
            currentInterval: current,
            previousInterval: interval("2026-07-26T22:00:00Z", "2026-08-02T22:00:00Z"),
            coverageStart: date("2026-07-01T00:00:00Z"),
            now: current.end.addingTimeInterval(-1),
            calendar: calendar
        )

        XCTAssertEqual(snapshot.totalFocusMinutes, 110)
        XCTAssertEqual(snapshot.estimateComposition, WorkPatternEstimateComposition(
            activityBackedMinutes: 55,
            bridgedMinutes: 55
        ))
        XCTAssertEqual(snapshot.blockProfile, WorkPatternBlockProfile(
            fiveToTenMinuteBlockCount: 1,
            fifteenToTwentyFiveMinuteBlockCount: 1,
            thirtyToFiftyFiveMinuteBlockCount: 1,
            sixtyPlusMinuteBlockCount: 1,
            sustainedFocusMinutes: 90,
            totalFocusMinutes: 110
        ))
        XCTAssertEqual(snapshot.toolMix, WorkPatternToolMix(
            claudeOnlyBlockCount: 1,
            codexOnlyBlockCount: 2,
            mixedBlockCount: 1
        ))
        XCTAssertEqual(snapshot.medianInteractionGapMinutes, 15)
    }

    func testFindsMidnightWrappingFocusWindowAndLocalScheduleRanges() throws {
        let calendar = amsterdamCalendar()
        let current = interval("2026-08-02T22:00:00Z", "2026-08-09T22:00:00Z")
        let activity = [
            slice("2026-08-03T21:00:00Z"),
            slice("2026-08-03T22:00:00Z"),
            slice("2026-08-04T21:10:00Z"),
            slice("2026-08-04T22:10:00Z"),
            slice("2026-08-05T21:30:00Z"),
            slice("2026-08-05T22:30:00Z"),
            slice("2026-08-06T22:00:00Z"),
        ]

        let snapshot = try WorkPatternCalculator().make(
            currentRows: [],
            currentActivity: activity,
            previousActivity: [],
            currentInterval: current,
            previousInterval: interval("2026-07-26T22:00:00Z", "2026-08-02T22:00:00Z"),
            coverageStart: date("2026-07-01T00:00:00Z"),
            now: current.end.addingTimeInterval(-1),
            calendar: calendar
        )

        XCTAssertEqual(snapshot.strongestFocusWindow, WorkPatternFocusWindow(
            startHour: 23,
            focusMinuteCount: 35,
            totalFocusMinuteCount: 35
        ))
        XCTAssertEqual(snapshot.firstActivityMinuteRange, WorkPatternMinuteRange(
            lowerMinuteOfDay: 0,
            medianMinuteOfDay: 0,
            upperMinuteOfDay: 10
        ))
        XCTAssertEqual(snapshot.lastActivityMinuteRange, WorkPatternMinuteRange(
            lowerMinuteOfDay: 1_390,
            medianMinuteOfDay: 1_410,
            upperMinuteOfDay: 0
        ))
    }

    func testEmptyActivityProducesZeroedDerivedInsightMetrics() throws {
        let calendar = amsterdamCalendar()
        let current = interval("2026-08-02T22:00:00Z", "2026-08-09T22:00:00Z")

        let snapshot = try WorkPatternCalculator().make(
            currentRows: [],
            currentActivity: [],
            previousActivity: [],
            currentInterval: current,
            previousInterval: interval("2026-07-26T22:00:00Z", "2026-08-02T22:00:00Z"),
            coverageStart: date("2026-07-01T00:00:00Z"),
            now: current.end.addingTimeInterval(-1),
            calendar: calendar
        )

        XCTAssertEqual(snapshot.estimateComposition, WorkPatternEstimateComposition(
            activityBackedMinutes: 0,
            bridgedMinutes: 0
        ))
        XCTAssertEqual(snapshot.blockProfile.totalBlockCount, 0)
        XCTAssertNil(snapshot.blockProfile.sustainedFocusShare)
        XCTAssertEqual(snapshot.toolMix.totalBlockCount, 0)
        XCTAssertNil(snapshot.strongestFocusWindow)
        XCTAssertNil(snapshot.firstActivityMinuteRange)
        XCTAssertNil(snapshot.lastActivityMinuteRange)
        XCTAssertNil(snapshot.medianInteractionGapMinutes)
    }

    func testTokenVolumeWithoutActivitySlicesDoesNotInventFocusTime() throws {
        let calendar = amsterdamCalendar()
        let current = interval("2026-08-02T22:00:00Z", "2026-08-09T22:00:00Z")

        let snapshot = try WorkPatternCalculator().make(
            currentRows: [row("2026-08-03T07:00:00Z", quantity: 300)],
            currentActivity: [],
            previousActivity: [],
            currentInterval: current,
            previousInterval: interval("2026-07-26T22:00:00Z", "2026-08-02T22:00:00Z"),
            coverageStart: date("2026-07-01T00:00:00Z"),
            now: current.end.addingTimeInterval(-1),
            calendar: calendar
        )

        XCTAssertEqual(snapshot.totalFocusMinutes, 0)
        XCTAssertEqual(snapshot.activeDayCount, 0)
        XCTAssertNil(snapshot.consistentHour)
        XCTAssertEqual(snapshot.volumePeakHour?.tokenTotal, 300)
    }

    func testPartialCoverageUsesOnlyCoveredCalendarDays() throws {
        let calendar = amsterdamCalendar()
        let current = interval("2026-08-02T22:00:00Z", "2026-08-16T22:00:00Z")
        let coverageStart = date("2026-08-10T07:35:00Z")

        let snapshot = try WorkPatternCalculator().make(
            currentRows: [row("2026-08-10T07:00:00Z", quantity: 10)],
            currentActivity: [slice("2026-08-10T07:35:00Z")],
            previousActivity: [],
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

    func testRepeatedDSTHourKeepsSeparateFocusBucketsWithoutInflatingFrequency() throws {
        let calendar = amsterdamCalendar()
        let current = interval("2026-10-24T22:00:00Z", "2026-10-26T23:00:00Z")
        let rows = [
            row("2026-10-25T00:15:00Z", quantity: 10),
            row("2026-10-25T01:15:00Z", quantity: 20),
        ]

        let snapshot = try WorkPatternCalculator().make(
            currentRows: rows,
            currentActivity: [
                slice("2026-10-25T00:15:00Z"),
                slice("2026-10-25T01:15:00Z"),
            ],
            previousActivity: [],
            currentInterval: current,
            previousInterval: interval("2026-10-22T22:00:00Z", "2026-10-24T22:00:00Z"),
            coverageStart: current.start,
            now: current.end.addingTimeInterval(-1),
            calendar: calendar
        )

        XCTAssertEqual(snapshot.totalFocusMinutes, 10)
        XCTAssertEqual(snapshot.focusSessionCount, 2)
        XCTAssertEqual(snapshot.activeDayCount, 1)
        XCTAssertEqual(snapshot.volumePeakHour?.hour, 2)
        XCTAssertEqual(snapshot.volumePeakHour?.tokenTotal, 30)
        XCTAssertEqual(snapshot.consistentHour?.activeOccurrenceCount, 1)
        XCTAssertEqual(snapshot.longestFocusSessionMinutes, 5)
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

    private func slice(
        _ value: String,
        provider: Provider = .codex
    ) -> ActivitySliceRow {
        let timestamp = date(value)
        return ActivitySliceRow(
            sliceStart: timestamp,
            localDay: LocalDay(date: timestamp, calendar: amsterdamCalendar()),
            provider: provider
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

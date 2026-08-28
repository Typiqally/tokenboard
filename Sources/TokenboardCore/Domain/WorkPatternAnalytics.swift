import Foundation

public enum WorkWeekday: Int, CaseIterable, Codable, Sendable {
    case monday = 1
    case tuesday
    case wednesday
    case thursday
    case friday
    case saturday
    case sunday

    init(calendarWeekday: Int) {
        self = WorkWeekday(rawValue: ((calendarWeekday + 5) % 7) + 1) ?? .monday
    }
}

public struct WorkPatternHourSummary: Equatable, Sendable {
    public let hour: Int
    public let tokenTotal: Int64
    public let activeOccurrenceCount: Int
    public let eligibleOccurrenceCount: Int

    public var consistency: Decimal {
        eligibleOccurrenceCount == 0
            ? 0
            : Decimal(activeOccurrenceCount) / Decimal(eligibleOccurrenceCount)
    }
}

public struct WorkPatternWeekdaySummary: Equatable, Sendable {
    public let weekday: WorkWeekday
    public let tokenTotal: Int64
    public let activeOccurrenceCount: Int
    public let eligibleOccurrenceCount: Int

    public var consistency: Decimal {
        eligibleOccurrenceCount == 0
            ? 0
            : Decimal(activeOccurrenceCount) / Decimal(eligibleOccurrenceCount)
    }
}

public struct WorkPatternDay: Equatable, Sendable {
    public let localDay: LocalDay
    public let activeHourCount: Int
    public let tokenTotal: Int64
    public let peakHour: Int?
    public let firstActivityHour: Int?
    public let lastActivityHour: Int?
    public let longestActiveRunHours: Int

    public var selectionID: String { "work-day:\(localDay.value)" }
}

public struct WorkPatternHeatmapCell: Equatable, Sendable {
    public let weekday: WorkWeekday
    public let hour: Int
    public let tokenTotal: Int64
    public let activeOccurrenceCount: Int
    public let eligibleOccurrenceCount: Int

    public var consistency: Decimal {
        eligibleOccurrenceCount == 0
            ? 0
            : Decimal(activeOccurrenceCount) / Decimal(eligibleOccurrenceCount)
    }

    public var selectionID: String { "heatmap:\(weekday.rawValue):\(hour)" }
}

public struct WorkPatternComparison: Equatable, Sendable {
    public let currentActiveHours: Int
    public let previousActiveHours: Int
    public let activeHourDelta: Int
    public let percentChange: Decimal?

    public init(
        currentActiveHours: Int,
        previousActiveHours: Int,
        activeHourDelta: Int,
        percentChange: Decimal?
    ) {
        self.currentActiveHours = currentActiveHours
        self.previousActiveHours = previousActiveHours
        self.activeHourDelta = activeHourDelta
        self.percentChange = percentChange
    }
}

public struct WorkPatternSnapshot: Equatable, Sendable {
    public let coverageStart: Date
    public let isCoveragePartial: Bool
    public let coveredCalendarDayCount: Int
    public let days: [WorkPatternDay]
    public let heatmap: [WorkPatternHeatmapCell]
    public let totalActiveHours: Int
    public let activeDayCount: Int
    public let averageActiveHoursPerActiveDay: Decimal?
    public let averageActiveDaysPerWeek: Decimal
    public let volumePeakHour: WorkPatternHourSummary?
    public let consistentHour: WorkPatternHourSummary?
    public let volumePeakWeekday: WorkPatternWeekdaySummary?
    public let consistentWeekday: WorkPatternWeekdaySummary?
    public let typicalFirstActivityHour: Int?
    public let typicalLastActivityHour: Int?
    public let longestActiveRunHours: Int
    public let busiestDay: WorkPatternDay?
    public let comparison: WorkPatternComparison?
}

public struct WorkPatternCalculator: Sendable {
    public init() {}

    public func make(
        currentRows: [HourlyUsageRow],
        previousRows: [HourlyUsageRow],
        currentInterval: DateInterval,
        previousInterval: DateInterval,
        coverageStart: Date,
        now: Date,
        calendar: Calendar
    ) throws -> WorkPatternSnapshot {
        guard let coverageHour = calendar.dateInterval(of: .hour, for: coverageStart)?.start,
              let currentDayEnd = calendar.dateInterval(of: .day, for: now)?.end else {
            throw UsageHistoryError.calendarArithmeticFailure
        }
        let effectiveStart = max(currentInterval.start, coverageHour)
        let effectiveEnd = min(currentInterval.end, currentDayEnd)
        let buckets = try activityBuckets(
            currentRows,
            interval: DateInterval(start: effectiveStart, end: effectiveEnd)
        )
        let days = try dailyActivity(
            buckets: buckets,
            start: effectiveStart,
            end: effectiveEnd,
            calendar: calendar
        )
        let activeDays = days.filter { $0.activeHourCount > 0 }
        let activeHours = activeDays.reduce(0) { $0 + $1.activeHourCount }
        let hours = try hourSummaries(buckets, activeDayCount: activeDays.count)
        let weekdays = weekdaySummaries(days, calendar: calendar)

        return WorkPatternSnapshot(
            coverageStart: coverageHour,
            isCoveragePartial: coverageHour > currentInterval.start,
            coveredCalendarDayCount: days.count,
            days: days,
            heatmap: try heatmap(buckets, days: days, calendar: calendar),
            totalActiveHours: activeHours,
            activeDayCount: activeDays.count,
            averageActiveHoursPerActiveDay: activeDays.isEmpty
                ? nil
                : Decimal(activeHours) / Decimal(activeDays.count),
            averageActiveDaysPerWeek: days.isEmpty
                ? 0
                : Decimal(activeDays.count) * 7 / Decimal(days.count),
            volumePeakHour: hours.sorted(by: volumeHourOrder).first,
            consistentHour: hours.sorted(by: consistentHourOrder).first,
            volumePeakWeekday: weekdays
                .filter { $0.tokenTotal > 0 }
                .sorted(by: volumeWeekdayOrder)
                .first,
            consistentWeekday: weekdays
                .filter { $0.activeOccurrenceCount > 0 }
                .sorted(by: consistentWeekdayOrder)
                .first,
            typicalFirstActivityHour: median(activeDays.compactMap(\.firstActivityHour)),
            typicalLastActivityHour: median(activeDays.compactMap(\.lastActivityHour)),
            longestActiveRunHours: activeDays.map(\.longestActiveRunHours).max() ?? 0,
            busiestDay: activeDays.sorted(by: busiestDayOrder).first,
            comparison: try comparison(
                currentActiveHours: activeHours,
                previousRows: previousRows,
                previousInterval: previousInterval,
                coverageHour: coverageHour
            )
        )
    }

    private func activityBuckets(
        _ rows: [HourlyUsageRow],
        interval: DateInterval
    ) throws -> [ActivityBucket] {
        var grouped: [ActivityBucketKey: ActivityBucket] = [:]
        for row in rows where row.aggregation == .additive && row.quantity > 0 {
            var localCalendar = Calendar(identifier: .gregorian)
            localCalendar.locale = Locale(identifier: "en_US_POSIX")
            localCalendar.timeZone = TimeZone(identifier: row.localDay.timeZoneIdentifier) ?? .current
            guard let hourStart = localCalendar.dateInterval(of: .hour, for: row.hourStart)?.start
            else { throw UsageHistoryError.calendarArithmeticFailure }
            guard hourStart >= interval.start, hourStart < interval.end else { continue }
            let key = ActivityBucketKey(hourStart: hourStart, localDayValue: row.localDay.value)
            let total = try checkedAdd(grouped[key]?.tokenTotal ?? 0, row.quantity)
            grouped[key] = ActivityBucket(
                hourStart: hourStart,
                localDay: row.localDay,
                hour: localCalendar.component(.hour, from: hourStart),
                weekday: WorkWeekday(
                    calendarWeekday: localCalendar.component(.weekday, from: hourStart)
                ),
                tokenTotal: total
            )
        }
        return grouped.values.sorted {
            if $0.hourStart != $1.hourStart { return $0.hourStart < $1.hourStart }
            return $0.localDay.value < $1.localDay.value
        }
    }

    private func dailyActivity(
        buckets: [ActivityBucket],
        start: Date,
        end: Date,
        calendar: Calendar
    ) throws -> [WorkPatternDay] {
        guard let firstDay = calendar.dateInterval(of: .day, for: start)?.start else {
            throw UsageHistoryError.calendarArithmeticFailure
        }
        let grouped = Dictionary(grouping: buckets, by: { $0.localDay.value })
        var result: [WorkPatternDay] = []
        var date = firstDay
        while date < end {
            let localDay = LocalDay(date: date, calendar: calendar)
            let values = grouped[localDay.value, default: []].sorted { $0.hourStart < $1.hourStart }
            let byHour = try totalsByHour(values)
            let peak = byHour.sorted {
                $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value
            }.first?.key
            let tokenTotal = try values.reduce(into: Int64.zero) {
                $0 = try checkedAdd($0, $1.tokenTotal)
            }
            result.append(WorkPatternDay(
                localDay: localDay,
                activeHourCount: values.count,
                tokenTotal: tokenTotal,
                peakHour: peak,
                firstActivityHour: values.first?.hour,
                lastActivityHour: values.last?.hour,
                longestActiveRunHours: longestRun(values)
            ))
            guard let next = calendar.date(byAdding: .day, value: 1, to: date) else {
                throw UsageHistoryError.calendarArithmeticFailure
            }
            date = next
        }
        return result
    }

    private func hourSummaries(
        _ buckets: [ActivityBucket],
        activeDayCount: Int
    ) throws -> [WorkPatternHourSummary] {
        try Dictionary(grouping: buckets, by: \.hour).map { hour, values in
            WorkPatternHourSummary(
                hour: hour,
                tokenTotal: try values.reduce(into: Int64.zero) {
                    $0 = try checkedAdd($0, $1.tokenTotal)
                },
                activeOccurrenceCount: Set(values.map { $0.localDay.value }).count,
                eligibleOccurrenceCount: activeDayCount
            )
        }
    }

    private func weekdaySummaries(
        _ days: [WorkPatternDay],
        calendar: Calendar
    ) -> [WorkPatternWeekdaySummary] {
        let weekdayByDay = Dictionary(uniqueKeysWithValues: days.map {
            ($0.localDay.value, weekday(for: $0.localDay, calendar: calendar))
        })
        return WorkWeekday.allCases.map { weekday in
            let eligible = days.filter { weekdayByDay[$0.localDay.value] == weekday }
            return WorkPatternWeekdaySummary(
                weekday: weekday,
                tokenTotal: eligible.reduce(0) { $0 + $1.tokenTotal },
                activeOccurrenceCount: eligible.filter { $0.activeHourCount > 0 }.count,
                eligibleOccurrenceCount: eligible.count
            )
        }
    }

    private func heatmap(
        _ buckets: [ActivityBucket],
        days: [WorkPatternDay],
        calendar: Calendar
    ) throws -> [WorkPatternHeatmapCell] {
        let grouped = Dictionary(grouping: buckets) {
            HeatmapKey(weekday: $0.weekday, hour: $0.hour)
        }
        let eligible = Dictionary(grouping: days) {
            weekday(for: $0.localDay, calendar: calendar)
        }.mapValues(\.count)
        return try WorkWeekday.allCases.flatMap { weekday in
            try (0..<24).map { hour in
                let values = grouped[HeatmapKey(weekday: weekday, hour: hour), default: []]
                return WorkPatternHeatmapCell(
                    weekday: weekday,
                    hour: hour,
                    tokenTotal: try values.reduce(into: Int64.zero) {
                        $0 = try checkedAdd($0, $1.tokenTotal)
                    },
                    activeOccurrenceCount: Set(values.map { $0.localDay.value }).count,
                    eligibleOccurrenceCount: eligible[weekday, default: 0]
                )
            }
        }
    }

    private func comparison(
        currentActiveHours: Int,
        previousRows: [HourlyUsageRow],
        previousInterval: DateInterval,
        coverageHour: Date
    ) throws -> WorkPatternComparison? {
        guard coverageHour <= previousInterval.start else { return nil }
        let previous = try activityBuckets(previousRows, interval: previousInterval).count
        let delta = currentActiveHours - previous
        return WorkPatternComparison(
            currentActiveHours: currentActiveHours,
            previousActiveHours: previous,
            activeHourDelta: delta,
            percentChange: previous == 0 ? nil : Decimal(delta) * 100 / Decimal(previous)
        )
    }

    private func totalsByHour(_ buckets: [ActivityBucket]) throws -> [Int: Int64] {
        var result: [Int: Int64] = [:]
        for bucket in buckets {
            result[bucket.hour] = try checkedAdd(result[bucket.hour, default: 0], bucket.tokenTotal)
        }
        return result
    }

    private func longestRun(_ buckets: [ActivityBucket]) -> Int {
        guard !buckets.isEmpty else { return 0 }
        var current = 1
        var longest = 1
        for (before, after) in zip(buckets, buckets.dropFirst()) {
            if abs(after.hourStart.timeIntervalSince(before.hourStart) - 3_600) < 1 {
                current += 1
                longest = max(longest, current)
            } else {
                current = 1
            }
        }
        return longest
    }

    private func weekday(for day: LocalDay, calendar: Calendar) -> WorkWeekday {
        let values = day.value.split(separator: "-").compactMap { Int($0) }
        guard values.count == 3 else { return .monday }
        var localCalendar = calendar
        localCalendar.timeZone = TimeZone(identifier: day.timeZoneIdentifier) ?? calendar.timeZone
        let components = DateComponents(
            calendar: localCalendar,
            timeZone: localCalendar.timeZone,
            year: values[0],
            month: values[1],
            day: values[2],
            hour: 12
        )
        guard let date = localCalendar.date(from: components) else { return .monday }
        return WorkWeekday(calendarWeekday: localCalendar.component(.weekday, from: date))
    }

    private func median(_ values: [Int]) -> Int? {
        values.isEmpty ? nil : values.sorted()[values.count / 2]
    }

    private func checkedAdd(_ lhs: Int64, _ rhs: Int64) throws -> Int64 {
        let (result, overflow) = lhs.addingReportingOverflow(rhs)
        guard !overflow else { throw UsageHistoryError.tokenTotalOverflow }
        return result
    }

    private func volumeHourOrder(_ lhs: WorkPatternHourSummary, _ rhs: WorkPatternHourSummary) -> Bool {
        if lhs.tokenTotal != rhs.tokenTotal { return lhs.tokenTotal > rhs.tokenTotal }
        if lhs.activeOccurrenceCount != rhs.activeOccurrenceCount {
            return lhs.activeOccurrenceCount > rhs.activeOccurrenceCount
        }
        return lhs.hour < rhs.hour
    }

    private func consistentHourOrder(_ lhs: WorkPatternHourSummary, _ rhs: WorkPatternHourSummary) -> Bool {
        if lhs.activeOccurrenceCount != rhs.activeOccurrenceCount {
            return lhs.activeOccurrenceCount > rhs.activeOccurrenceCount
        }
        if lhs.tokenTotal != rhs.tokenTotal { return lhs.tokenTotal > rhs.tokenTotal }
        return lhs.hour < rhs.hour
    }

    private func volumeWeekdayOrder(
        _ lhs: WorkPatternWeekdaySummary,
        _ rhs: WorkPatternWeekdaySummary
    ) -> Bool {
        if lhs.tokenTotal != rhs.tokenTotal { return lhs.tokenTotal > rhs.tokenTotal }
        if lhs.consistency != rhs.consistency { return lhs.consistency > rhs.consistency }
        return lhs.weekday.rawValue < rhs.weekday.rawValue
    }

    private func consistentWeekdayOrder(
        _ lhs: WorkPatternWeekdaySummary,
        _ rhs: WorkPatternWeekdaySummary
    ) -> Bool {
        if lhs.consistency != rhs.consistency { return lhs.consistency > rhs.consistency }
        if lhs.tokenTotal != rhs.tokenTotal { return lhs.tokenTotal > rhs.tokenTotal }
        return lhs.weekday.rawValue < rhs.weekday.rawValue
    }

    private func busiestDayOrder(_ lhs: WorkPatternDay, _ rhs: WorkPatternDay) -> Bool {
        lhs.tokenTotal == rhs.tokenTotal
            ? lhs.localDay.value > rhs.localDay.value
            : lhs.tokenTotal > rhs.tokenTotal
    }
}

private struct ActivityBucketKey: Hashable {
    let hourStart: Date
    let localDayValue: String
}

private struct ActivityBucket {
    let hourStart: Date
    let localDay: LocalDay
    let hour: Int
    let weekday: WorkWeekday
    let tokenTotal: Int64
}

private struct HeatmapKey: Hashable {
    let weekday: WorkWeekday
    let hour: Int
}

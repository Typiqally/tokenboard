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
    public let focusMinuteCount: Int
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
    public let focusMinuteCount: Int
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
    public let focusMinuteCount: Int
    public let focusSessionCount: Int
    public let tokenTotal: Int64
    public let peakHour: Int?
    public let firstActivityHour: Int?
    public let lastActivityHour: Int?
    public let longestFocusSessionMinutes: Int

    public var selectionID: String { "work-day:\(localDay.value)" }
}

public struct WorkPatternHeatmapCell: Equatable, Sendable {
    public let weekday: WorkWeekday
    public let hour: Int
    public let tokenTotal: Int64
    public let focusMinuteCount: Int
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
    public let currentFocusMinutes: Int
    public let previousFocusMinutes: Int
    public let focusMinuteDelta: Int
    public let percentChange: Decimal?

    public init(
        currentFocusMinutes: Int,
        previousFocusMinutes: Int,
        focusMinuteDelta: Int,
        percentChange: Decimal?
    ) {
        self.currentFocusMinutes = currentFocusMinutes
        self.previousFocusMinutes = previousFocusMinutes
        self.focusMinuteDelta = focusMinuteDelta
        self.percentChange = percentChange
    }
}

public struct WorkPatternEstimateComposition: Equatable, Sendable {
    public let activityBackedMinutes: Int
    public let bridgedMinutes: Int

    public init(activityBackedMinutes: Int, bridgedMinutes: Int) {
        self.activityBackedMinutes = activityBackedMinutes
        self.bridgedMinutes = bridgedMinutes
    }

    public var totalMinutes: Int { activityBackedMinutes + bridgedMinutes }

    public var activityBackedShare: Decimal? {
        totalMinutes == 0 ? nil : Decimal(activityBackedMinutes) / Decimal(totalMinutes)
    }
}

public struct WorkPatternBlockProfile: Equatable, Sendable {
    public let fiveToTenMinuteBlockCount: Int
    public let fifteenToTwentyFiveMinuteBlockCount: Int
    public let thirtyToFiftyFiveMinuteBlockCount: Int
    public let sixtyPlusMinuteBlockCount: Int
    public let sustainedFocusMinutes: Int
    public let totalFocusMinutes: Int

    public init(
        fiveToTenMinuteBlockCount: Int,
        fifteenToTwentyFiveMinuteBlockCount: Int,
        thirtyToFiftyFiveMinuteBlockCount: Int,
        sixtyPlusMinuteBlockCount: Int,
        sustainedFocusMinutes: Int,
        totalFocusMinutes: Int
    ) {
        self.fiveToTenMinuteBlockCount = fiveToTenMinuteBlockCount
        self.fifteenToTwentyFiveMinuteBlockCount = fifteenToTwentyFiveMinuteBlockCount
        self.thirtyToFiftyFiveMinuteBlockCount = thirtyToFiftyFiveMinuteBlockCount
        self.sixtyPlusMinuteBlockCount = sixtyPlusMinuteBlockCount
        self.sustainedFocusMinutes = sustainedFocusMinutes
        self.totalFocusMinutes = totalFocusMinutes
    }

    public var totalBlockCount: Int {
        fiveToTenMinuteBlockCount
            + fifteenToTwentyFiveMinuteBlockCount
            + thirtyToFiftyFiveMinuteBlockCount
            + sixtyPlusMinuteBlockCount
    }

    public var sustainedFocusShare: Decimal? {
        totalFocusMinutes == 0
            ? nil
            : Decimal(sustainedFocusMinutes) / Decimal(totalFocusMinutes)
    }
}

public struct WorkPatternToolMix: Equatable, Sendable {
    public let claudeOnlyBlockCount: Int
    public let codexOnlyBlockCount: Int
    public let mixedBlockCount: Int

    public init(
        claudeOnlyBlockCount: Int,
        codexOnlyBlockCount: Int,
        mixedBlockCount: Int
    ) {
        self.claudeOnlyBlockCount = claudeOnlyBlockCount
        self.codexOnlyBlockCount = codexOnlyBlockCount
        self.mixedBlockCount = mixedBlockCount
    }

    public var totalBlockCount: Int {
        claudeOnlyBlockCount + codexOnlyBlockCount + mixedBlockCount
    }
}

public struct WorkPatternFocusWindow: Equatable, Sendable {
    public let startHour: Int
    public let focusMinuteCount: Int
    public let totalFocusMinuteCount: Int

    public init(startHour: Int, focusMinuteCount: Int, totalFocusMinuteCount: Int) {
        self.startHour = startHour
        self.focusMinuteCount = focusMinuteCount
        self.totalFocusMinuteCount = totalFocusMinuteCount
    }

    public var endHour: Int { (startHour + 2) % 24 }

    public var focusShare: Decimal? {
        totalFocusMinuteCount == 0
            ? nil
            : Decimal(focusMinuteCount) / Decimal(totalFocusMinuteCount)
    }
}

public struct WorkPatternMinuteRange: Equatable, Sendable {
    public let lowerMinuteOfDay: Int
    public let medianMinuteOfDay: Int
    public let upperMinuteOfDay: Int

    public init(
        lowerMinuteOfDay: Int,
        medianMinuteOfDay: Int,
        upperMinuteOfDay: Int
    ) {
        self.lowerMinuteOfDay = lowerMinuteOfDay
        self.medianMinuteOfDay = medianMinuteOfDay
        self.upperMinuteOfDay = upperMinuteOfDay
    }
}

public struct WorkPatternSnapshot: Equatable, Sendable {
    public let coverageStart: Date
    public let isCoveragePartial: Bool
    public let coveredCalendarDayCount: Int
    public let days: [WorkPatternDay]
    public let heatmap: [WorkPatternHeatmapCell]
    public let totalFocusMinutes: Int
    public let focusSessionCount: Int
    public let activeDayCount: Int
    public let averageFocusMinutesPerActiveDay: Decimal?
    public let averageFocusSessionMinutes: Decimal?
    public let averageActiveDaysPerWeek: Decimal
    public let volumePeakHour: WorkPatternHourSummary?
    public let consistentHour: WorkPatternHourSummary?
    public let volumePeakWeekday: WorkPatternWeekdaySummary?
    public let consistentWeekday: WorkPatternWeekdaySummary?
    public let typicalFirstActivityHour: Int?
    public let typicalLastActivityHour: Int?
    public let longestFocusSessionMinutes: Int
    public let busiestDay: WorkPatternDay?
    public let comparison: WorkPatternComparison?
    public let estimateComposition: WorkPatternEstimateComposition
    public let blockProfile: WorkPatternBlockProfile
    public let toolMix: WorkPatternToolMix
    public let strongestFocusWindow: WorkPatternFocusWindow?
    public let firstActivityMinuteRange: WorkPatternMinuteRange?
    public let lastActivityMinuteRange: WorkPatternMinuteRange?
    public let medianInteractionGapMinutes: Int?
    public let interactionGapCount: Int
}

public struct WorkPatternCalculator: Sendable {
    public static let activitySliceMinutes = 5
    public static let maximumSliceGapMinutes = 15

    public init() {}

    public func make(
        currentRows: [HourlyUsageRow],
        currentActivity: [ActivitySliceRow],
        previousActivity: [ActivitySliceRow],
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
        let interval = DateInterval(start: effectiveStart, end: effectiveEnd)
        let focus = try focusEstimate(currentActivity, interval: interval)
        let buckets = try activityBuckets(
            currentRows,
            focusBuckets: focus.buckets,
            interval: interval
        )
        let days = try dailyActivity(
            buckets: buckets,
            sessions: focus.sessions,
            start: effectiveStart,
            end: effectiveEnd,
            calendar: calendar
        )
        let activeDays = days.filter { $0.focusMinuteCount > 0 }
        let totalFocusMinutes = activeDays.reduce(0) { $0 + $1.focusMinuteCount }
        let focusSessionCount = activeDays.reduce(0) { $0 + $1.focusSessionCount }
        let hours = try hourSummaries(buckets, activeDayCount: activeDays.count)
        let weekdays = try weekdaySummaries(days, calendar: calendar)
        let activityBackedMinutes = focus.activitySliceCount * Self.activitySliceMinutes
        let schedule = try scheduleActivity(
            slices: focus.slices,
            calendarDayCount: days.count
        )

        return WorkPatternSnapshot(
            coverageStart: coverageHour,
            isCoveragePartial: coverageHour > currentInterval.start,
            coveredCalendarDayCount: days.count,
            days: days,
            heatmap: try heatmap(buckets, days: days, calendar: calendar),
            totalFocusMinutes: totalFocusMinutes,
            focusSessionCount: focusSessionCount,
            activeDayCount: activeDays.count,
            averageFocusMinutesPerActiveDay: activeDays.isEmpty
                ? nil
                : Decimal(totalFocusMinutes) / Decimal(activeDays.count),
            averageFocusSessionMinutes: focusSessionCount == 0
                ? nil
                : Decimal(totalFocusMinutes) / Decimal(focusSessionCount),
            averageActiveDaysPerWeek: days.isEmpty
                ? 0
                : Decimal(activeDays.count) * 7 / Decimal(days.count),
            volumePeakHour: hours
                .filter { $0.tokenTotal > 0 }
                .sorted(by: volumeHourOrder)
                .first,
            consistentHour: hours
                .filter { $0.activeOccurrenceCount > 0 }
                .sorted(by: consistentHourOrder)
                .first,
            volumePeakWeekday: weekdays
                .filter { $0.tokenTotal > 0 }
                .sorted(by: volumeWeekdayOrder)
                .first,
            consistentWeekday: weekdays
                .filter { $0.activeOccurrenceCount > 0 }
                .sorted(by: consistentWeekdayOrder)
                .first,
            typicalFirstActivityHour: medianScheduleMinute(
                schedule.firstMinutes,
                scheduleStartMinute: schedule.startMinute
            ).map { $0 / 60 },
            typicalLastActivityHour: medianScheduleMinute(
                schedule.lastMinutes,
                scheduleStartMinute: schedule.startMinute
            ).map { $0 / 60 },
            longestFocusSessionMinutes: activeDays
                .map(\.longestFocusSessionMinutes)
                .max() ?? 0,
            busiestDay: activeDays.sorted(by: busiestDayOrder).first,
            comparison: try comparison(
                currentFocusMinutes: totalFocusMinutes,
                previousActivity: previousActivity,
                previousInterval: previousInterval,
                coverageHour: coverageHour
            ),
            estimateComposition: WorkPatternEstimateComposition(
                activityBackedMinutes: activityBackedMinutes,
                bridgedMinutes: max(totalFocusMinutes - activityBackedMinutes, 0)
            ),
            blockProfile: blockProfile(
                sessions: focus.sessions,
                totalFocusMinutes: totalFocusMinutes
            ),
            toolMix: toolMix(sessions: focus.sessions),
            strongestFocusWindow: strongestFocusWindow(
                hours: hours,
                totalFocusMinutes: totalFocusMinutes
            ),
            firstActivityMinuteRange: activityMinuteRange(schedule.firstMinutes),
            lastActivityMinuteRange: activityMinuteRange(schedule.lastMinutes),
            medianInteractionGapMinutes: median(focus.interactionGapMinutes),
            interactionGapCount: focus.interactionGapMinutes.count
        )
    }

    private func activityBuckets(
        _ rows: [HourlyUsageRow],
        focusBuckets: [ActivityBucketKey: FocusBucket],
        interval: DateInterval
    ) throws -> [ActivityBucket] {
        var grouped: [ActivityBucketKey: ActivityBucket] = [:]
        for row in rows where row.aggregation == .additive && row.quantity > 0 {
            let localCalendar = calendar(for: row.localDay)
            guard let hourStart = localCalendar.dateInterval(of: .hour, for: row.hourStart)?.start
            else { throw UsageHistoryError.calendarArithmeticFailure }
            guard hourStart >= interval.start, hourStart < interval.end else { continue }
            let key = ActivityBucketKey(hourStart: hourStart, localDayValue: row.localDay.value)
            let total = try checkedAdd(grouped[key]?.tokenTotal ?? 0, row.quantity)
            grouped[key] = bucket(
                hourStart: hourStart,
                localDay: row.localDay,
                tokenTotal: total,
                focusMinuteCount: grouped[key]?.focusMinuteCount ?? 0
            )
        }
        for (key, focus) in focusBuckets {
            if let existing = grouped[key] {
                grouped[key] = bucket(
                    hourStart: existing.hourStart,
                    localDay: existing.localDay,
                    tokenTotal: existing.tokenTotal,
                    focusMinuteCount: focus.minuteCount
                )
            } else {
                grouped[key] = bucket(
                    hourStart: key.hourStart,
                    localDay: focus.localDay,
                    tokenTotal: 0,
                    focusMinuteCount: focus.minuteCount
                )
            }
        }
        return grouped.values.sorted {
            if $0.hourStart != $1.hourStart { return $0.hourStart < $1.hourStart }
            return $0.localDay.value < $1.localDay.value
        }
    }

    private func dailyActivity(
        buckets: [ActivityBucket],
        sessions: [FocusSession],
        start: Date,
        end: Date,
        calendar: Calendar
    ) throws -> [WorkPatternDay] {
        guard let firstDay = calendar.dateInterval(of: .day, for: start)?.start else {
            throw UsageHistoryError.calendarArithmeticFailure
        }
        let grouped = Dictionary(grouping: buckets, by: { $0.localDay.value })
        let sessionsByDay = Dictionary(grouping: sessions, by: { $0.localDay.value })
        var result: [WorkPatternDay] = []
        var date = firstDay
        while date < end {
            let localDay = LocalDay(date: date, calendar: calendar)
            let values = grouped[localDay.value, default: []].sorted { $0.hourStart < $1.hourStart }
            let focusValues = values.filter { $0.focusMinuteCount > 0 }
            let byHour = try totalsByHour(values)
            let peak = byHour
                .filter { $0.value > 0 }
                .sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
                .first?.key
            let tokenTotal = try values.reduce(into: Int64.zero) {
                $0 = try checkedAdd($0, $1.tokenTotal)
            }
            let daySessions = sessionsByDay[localDay.value, default: []]
            result.append(WorkPatternDay(
                localDay: localDay,
                focusMinuteCount: focusValues.reduce(0) { $0 + $1.focusMinuteCount },
                focusSessionCount: daySessions.count,
                tokenTotal: tokenTotal,
                peakHour: peak,
                firstActivityHour: focusValues.first?.hour,
                lastActivityHour: focusValues.last?.hour,
                longestFocusSessionMinutes: daySessions.map(\.minuteCount).max() ?? 0
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
                focusMinuteCount: values.reduce(0) { $0 + $1.focusMinuteCount },
                activeOccurrenceCount: Set(
                    values.filter { $0.focusMinuteCount > 0 }.map { $0.localDay.value }
                ).count,
                eligibleOccurrenceCount: activeDayCount
            )
        }
    }

    private func weekdaySummaries(
        _ days: [WorkPatternDay],
        calendar: Calendar
    ) throws -> [WorkPatternWeekdaySummary] {
        let weekdayByDay = Dictionary(uniqueKeysWithValues: days.map {
            ($0.localDay.value, weekday(for: $0.localDay, calendar: calendar))
        })
        return try WorkWeekday.allCases.map { weekday in
            let eligible = days.filter { weekdayByDay[$0.localDay.value] == weekday }
            return WorkPatternWeekdaySummary(
                weekday: weekday,
                tokenTotal: try eligible.reduce(into: Int64.zero) {
                    $0 = try checkedAdd($0, $1.tokenTotal)
                },
                focusMinuteCount: eligible.reduce(0) { $0 + $1.focusMinuteCount },
                activeOccurrenceCount: eligible.filter { $0.focusMinuteCount > 0 }.count,
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
                    focusMinuteCount: values.reduce(0) { $0 + $1.focusMinuteCount },
                    activeOccurrenceCount: Set(
                        values.filter { $0.focusMinuteCount > 0 }.map { $0.localDay.value }
                    ).count,
                    eligibleOccurrenceCount: eligible[weekday, default: 0]
                )
            }
        }
    }

    private func comparison(
        currentFocusMinutes: Int,
        previousActivity: [ActivitySliceRow],
        previousInterval: DateInterval,
        coverageHour: Date
    ) throws -> WorkPatternComparison? {
        guard coverageHour <= previousInterval.start else { return nil }
        let previous = try focusEstimate(previousActivity, interval: previousInterval).totalMinutes
        let delta = currentFocusMinutes - previous
        return WorkPatternComparison(
            currentFocusMinutes: currentFocusMinutes,
            previousFocusMinutes: previous,
            focusMinuteDelta: delta,
            percentChange: previous == 0 ? nil : Decimal(delta) * 100 / Decimal(previous)
        )
    }

    private func focusEstimate(
        _ rows: [ActivitySliceRow],
        interval: DateInterval
    ) throws -> FocusEstimate {
        var unique: [ActivitySliceIdentity: ActivitySlice] = [:]
        for row in rows {
            let sliceStart = fiveMinuteStart(row.sliceStart)
            guard sliceStart >= interval.start, sliceStart < interval.end else { continue }
            let localCalendar = calendar(for: row.localDay)
            let localDay = LocalDay(date: sliceStart, calendar: localCalendar)
            let identity = ActivitySliceIdentity(
                sliceStart: sliceStart,
                localDayValue: localDay.value,
                timeZoneIdentifier: localDay.timeZoneIdentifier
            )
            if let existing = unique[identity] {
                unique[identity] = ActivitySlice(
                    sliceStart: sliceStart,
                    localDay: localDay,
                    providers: existing.providers.union([row.provider])
                )
            } else {
                unique[identity] = ActivitySlice(
                    sliceStart: sliceStart,
                    localDay: localDay,
                    providers: [row.provider]
                )
            }
        }

        let byDay = Dictionary(grouping: unique.values) {
            FocusDayKey(
                localDayValue: $0.localDay.value,
                timeZoneIdentifier: $0.localDay.timeZoneIdentifier
            )
        }
        var sessions: [FocusSession] = []
        for values in byDay.values {
            let sorted = values.sorted { $0.sliceStart < $1.sliceStart }
            guard let first = sorted.first else { continue }
            var sessionSlices = [first]
            for slice in sorted.dropFirst() {
                guard let previousSlice = sessionSlices.last else { continue }
                let gapMinutes = slice.sliceStart.timeIntervalSince(previousSlice.sliceStart) / 60
                if gapMinutes <= Double(Self.maximumSliceGapMinutes) {
                    sessionSlices.append(slice)
                } else {
                    sessions.append(FocusSession(slices: sessionSlices))
                    sessionSlices = [slice]
                }
            }
            sessions.append(FocusSession(slices: sessionSlices))
        }
        sessions.sort { $0.firstSliceStart < $1.firstSliceStart }

        var focusBuckets: [ActivityBucketKey: FocusBucket] = [:]
        for session in sessions {
            let localCalendar = calendar(for: session.localDay)
            var sliceStart = session.firstSliceStart
            while sliceStart <= session.lastSliceStart {
                guard let hourStart = localCalendar.dateInterval(of: .hour, for: sliceStart)?.start else {
                    throw UsageHistoryError.calendarArithmeticFailure
                }
                let localDay = LocalDay(date: sliceStart, calendar: localCalendar)
                let key = ActivityBucketKey(
                    hourStart: hourStart,
                    localDayValue: localDay.value
                )
                let existingMinutes = focusBuckets[key]?.minuteCount ?? 0
                focusBuckets[key] = FocusBucket(
                    localDay: localDay,
                    minuteCount: existingMinutes + Self.activitySliceMinutes
                )
                sliceStart = sliceStart.addingTimeInterval(
                    TimeInterval(Self.activitySliceMinutes * 60)
                )
            }
        }
        return FocusEstimate(buckets: focusBuckets, sessions: sessions)
    }

    private func blockProfile(
        sessions: [FocusSession],
        totalFocusMinutes: Int
    ) -> WorkPatternBlockProfile {
        var fiveToTen = 0
        var fifteenToTwentyFive = 0
        var thirtyToFiftyFive = 0
        var sixtyPlus = 0
        var sustainedMinutes = 0
        for session in sessions {
            switch session.minuteCount {
            case ...10:
                fiveToTen += 1
            case ...25:
                fifteenToTwentyFive += 1
            case ...55:
                thirtyToFiftyFive += 1
                sustainedMinutes += session.minuteCount
            default:
                sixtyPlus += 1
                sustainedMinutes += session.minuteCount
            }
        }
        return WorkPatternBlockProfile(
            fiveToTenMinuteBlockCount: fiveToTen,
            fifteenToTwentyFiveMinuteBlockCount: fifteenToTwentyFive,
            thirtyToFiftyFiveMinuteBlockCount: thirtyToFiftyFive,
            sixtyPlusMinuteBlockCount: sixtyPlus,
            sustainedFocusMinutes: sustainedMinutes,
            totalFocusMinutes: totalFocusMinutes
        )
    }

    private func toolMix(sessions: [FocusSession]) -> WorkPatternToolMix {
        var claudeOnly = 0
        var codexOnly = 0
        var mixed = 0
        for session in sessions {
            if session.providers == [.claudeCode] {
                claudeOnly += 1
            } else if session.providers == [.codex] {
                codexOnly += 1
            } else {
                mixed += 1
            }
        }
        return WorkPatternToolMix(
            claudeOnlyBlockCount: claudeOnly,
            codexOnlyBlockCount: codexOnly,
            mixedBlockCount: mixed
        )
    }

    private func strongestFocusWindow(
        hours: [WorkPatternHourSummary],
        totalFocusMinutes: Int
    ) -> WorkPatternFocusWindow? {
        guard totalFocusMinutes > 0 else { return nil }
        let focusByHour = Dictionary(uniqueKeysWithValues: hours.map {
            ($0.hour, $0.focusMinuteCount)
        })
        let strongest = (0..<24).map { startHour in
            (
                startHour: startHour,
                focusMinutes: focusByHour[startHour, default: 0]
                    + focusByHour[(startHour + 1) % 24, default: 0]
            )
        }.max {
            if $0.focusMinutes != $1.focusMinutes {
                return $0.focusMinutes < $1.focusMinutes
            }
            return $0.startHour > $1.startHour
        }
        guard let strongest else { return nil }
        return WorkPatternFocusWindow(
            startHour: strongest.startHour,
            focusMinuteCount: strongest.focusMinutes,
            totalFocusMinuteCount: totalFocusMinutes
        )
    }

    private func scheduleActivity(
        slices: [ActivitySlice],
        calendarDayCount: Int
    ) throws -> ScheduleActivity {
        let observations = slices.map { slice in
            ScheduleActivityObservation(
                slice: slice,
                minuteOfDay: minuteOfDay(for: slice)
            )
        }
        let circularMinutes = circularlySortedMinutes(
            observations.map(\.minuteOfDay).sorted()
        )
        guard let firstCircularMinute = circularMinutes.first else {
            return ScheduleActivity(startMinute: nil, firstMinutes: [], lastMinutes: [])
        }
        let scheduleStartMinute = clockMinute(firstCircularMinute)

        if calendarDayCount == 1 {
            let ordered = observations.sorted {
                scheduleMinute($0.minuteOfDay, relativeTo: scheduleStartMinute)
                    < scheduleMinute($1.minuteOfDay, relativeTo: scheduleStartMinute)
            }
            return ScheduleActivity(
                startMinute: scheduleStartMinute,
                firstMinutes: ordered.first.map { [$0.minuteOfDay] } ?? [],
                lastMinutes: ordered.last.map { [$0.minuteOfDay] } ?? []
            )
        }

        var byWorkday: [FocusDayKey: [ScheduleActivityObservation]] = [:]
        for observation in observations {
            let localCalendar = calendar(for: observation.slice.localDay)
            guard let shiftedDate = localCalendar.date(
                byAdding: .minute,
                value: -scheduleStartMinute,
                to: observation.slice.sliceStart
            ) else {
                throw UsageHistoryError.calendarArithmeticFailure
            }
            let shiftedDay = LocalDay(date: shiftedDate, calendar: localCalendar)
            let key = FocusDayKey(
                localDayValue: shiftedDay.value,
                timeZoneIdentifier: shiftedDay.timeZoneIdentifier
            )
            byWorkday[key, default: []].append(observation)
        }

        let workdays = byWorkday.values.map { observations in
            observations.sorted {
                scheduleMinute($0.minuteOfDay, relativeTo: scheduleStartMinute)
                    < scheduleMinute($1.minuteOfDay, relativeTo: scheduleStartMinute)
            }
        }
        return ScheduleActivity(
            startMinute: scheduleStartMinute,
            firstMinutes: workdays.compactMap { $0.first?.minuteOfDay },
            lastMinutes: workdays.compactMap { $0.last?.minuteOfDay }
        )
    }

    private func minuteOfDay(for slice: ActivitySlice) -> Int {
        let localCalendar = calendar(for: slice.localDay)
        let components = localCalendar.dateComponents([.hour, .minute], from: slice.sliceStart)
        return (components.hour ?? 0) * 60 + (components.minute ?? 0)
    }

    private func scheduleMinute(_ minute: Int, relativeTo startMinute: Int) -> Int {
        minute >= startMinute ? minute : minute + 1_440
    }

    private func medianScheduleMinute(
        _ minutes: [Int],
        scheduleStartMinute: Int?
    ) -> Int? {
        guard let scheduleStartMinute, !minutes.isEmpty else { return nil }
        let ordered = minutes
            .map { scheduleMinute($0, relativeTo: scheduleStartMinute) }
            .sorted()
        return clockMinute(ordered[ordered.count / 2])
    }

    private func activityMinuteRange(_ values: [Int]) -> WorkPatternMinuteRange? {
        let values = values.sorted()
        guard !values.isEmpty else { return nil }
        let circularValues = circularlySortedMinutes(values)
        return WorkPatternMinuteRange(
            lowerMinuteOfDay: clockMinute(nearestRank(circularValues, percentile: 0.25)),
            medianMinuteOfDay: clockMinute(nearestRank(circularValues, percentile: 0.5)),
            upperMinuteOfDay: clockMinute(nearestRank(circularValues, percentile: 0.75))
        )
    }

    private func circularlySortedMinutes(_ sortedValues: [Int]) -> [Int] {
        guard let first = sortedValues.first, let last = sortedValues.last else { return [] }
        var largestGapIndex = sortedValues.count - 1
        var largestGap = first + 1_440 - last
        for index in 0..<(sortedValues.count - 1) {
            let gap = sortedValues[index + 1] - sortedValues[index]
            if gap > largestGap {
                largestGap = gap
                largestGapIndex = index
            }
        }

        let startIndex = (largestGapIndex + 1) % sortedValues.count
        return (0..<sortedValues.count).map { offset in
            let index = (startIndex + offset) % sortedValues.count
            return sortedValues[index] + (index < startIndex ? 1_440 : 0)
        }
    }

    private func clockMinute(_ value: Int) -> Int {
        value % 1_440
    }

    private func nearestRank(_ sortedValues: [Int], percentile: Double) -> Int {
        let rank = max(Int(ceil(percentile * Double(sortedValues.count))), 1)
        return sortedValues[rank - 1]
    }

    private func bucket(
        hourStart: Date,
        localDay: LocalDay,
        tokenTotal: Int64,
        focusMinuteCount: Int
    ) -> ActivityBucket {
        let localCalendar = calendar(for: localDay)
        return ActivityBucket(
            hourStart: hourStart,
            localDay: localDay,
            hour: localCalendar.component(.hour, from: hourStart),
            weekday: WorkWeekday(
                calendarWeekday: localCalendar.component(.weekday, from: hourStart)
            ),
            tokenTotal: tokenTotal,
            focusMinuteCount: focusMinuteCount
        )
    }

    private func totalsByHour(_ buckets: [ActivityBucket]) throws -> [Int: Int64] {
        var result: [Int: Int64] = [:]
        for bucket in buckets {
            result[bucket.hour] = try checkedAdd(
                result[bucket.hour, default: 0],
                bucket.tokenTotal
            )
        }
        return result
    }

    private func calendar(for localDay: LocalDay) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = TimeZone(identifier: localDay.timeZoneIdentifier) ?? .current
        return calendar
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

    private func fiveMinuteStart(_ date: Date) -> Date {
        Date(timeIntervalSince1970: floor(date.timeIntervalSince1970 / 300) * 300)
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
        if lhs.focusMinuteCount != rhs.focusMinuteCount {
            return lhs.focusMinuteCount > rhs.focusMinuteCount
        }
        return lhs.hour < rhs.hour
    }

    private func consistentHourOrder(_ lhs: WorkPatternHourSummary, _ rhs: WorkPatternHourSummary) -> Bool {
        if lhs.activeOccurrenceCount != rhs.activeOccurrenceCount {
            return lhs.activeOccurrenceCount > rhs.activeOccurrenceCount
        }
        if lhs.focusMinuteCount != rhs.focusMinuteCount {
            return lhs.focusMinuteCount > rhs.focusMinuteCount
        }
        if lhs.tokenTotal != rhs.tokenTotal { return lhs.tokenTotal > rhs.tokenTotal }
        return lhs.hour < rhs.hour
    }

    private func volumeWeekdayOrder(
        _ lhs: WorkPatternWeekdaySummary,
        _ rhs: WorkPatternWeekdaySummary
    ) -> Bool {
        if lhs.tokenTotal != rhs.tokenTotal { return lhs.tokenTotal > rhs.tokenTotal }
        if lhs.focusMinuteCount != rhs.focusMinuteCount {
            return lhs.focusMinuteCount > rhs.focusMinuteCount
        }
        return lhs.weekday.rawValue < rhs.weekday.rawValue
    }

    private func consistentWeekdayOrder(
        _ lhs: WorkPatternWeekdaySummary,
        _ rhs: WorkPatternWeekdaySummary
    ) -> Bool {
        if lhs.consistency != rhs.consistency { return lhs.consistency > rhs.consistency }
        if lhs.focusMinuteCount != rhs.focusMinuteCount {
            return lhs.focusMinuteCount > rhs.focusMinuteCount
        }
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
    let focusMinuteCount: Int
}

private struct ActivitySliceIdentity: Hashable {
    let sliceStart: Date
    let localDayValue: String
    let timeZoneIdentifier: String
}

private struct ActivitySlice {
    let sliceStart: Date
    let localDay: LocalDay
    let providers: Set<Provider>
}

private struct ScheduleActivityObservation {
    let slice: ActivitySlice
    let minuteOfDay: Int
}

private struct ScheduleActivity {
    let startMinute: Int?
    let firstMinutes: [Int]
    let lastMinutes: [Int]
}

private struct FocusDayKey: Hashable {
    let localDayValue: String
    let timeZoneIdentifier: String
}

private struct FocusSession {
    let slices: [ActivitySlice]

    var firstSliceStart: Date { slices[0].sliceStart }
    var lastSliceStart: Date { slices[slices.count - 1].sliceStart }
    var localDay: LocalDay { slices[0].localDay }
    var providers: Set<Provider> {
        slices.reduce(into: Set<Provider>()) { $0.formUnion($1.providers) }
    }
    var interactionGapMinutes: [Int] {
        zip(slices, slices.dropFirst()).map { previous, current in
            Int(current.sliceStart.timeIntervalSince(previous.sliceStart) / 60)
        }
    }

    var minuteCount: Int {
        Int(lastSliceStart.timeIntervalSince(firstSliceStart) / 60)
            + WorkPatternCalculator.activitySliceMinutes
    }
}

private struct FocusEstimate {
    let buckets: [ActivityBucketKey: FocusBucket]
    let sessions: [FocusSession]

    var totalMinutes: Int { sessions.reduce(0) { $0 + $1.minuteCount } }
    var slices: [ActivitySlice] { sessions.flatMap(\.slices) }
    var activitySliceCount: Int { sessions.reduce(0) { $0 + $1.slices.count } }
    var interactionGapMinutes: [Int] { sessions.flatMap(\.interactionGapMinutes) }
}

private struct FocusBucket {
    let localDay: LocalDay
    let minuteCount: Int
}

private struct HeatmapKey: Hashable {
    let weekday: WorkWeekday
    let hour: Int
}

import Foundation

public struct UsageQueryService: Sendable {
    private let ledger: any LedgerStore

    public init(ledger: any LedgerStore) {
        self.ledger = ledger
    }

    public func summary(
        period: CalendarPeriod,
        now: Date,
        calendar: Calendar
    ) async throws -> UsageSummary {
        let interval = period.interval(containing: now, calendar: calendar)
        let rows = try await ledger.usageRows(in: interval, calendar: calendar)
        let pricing = try await ledger.pricingSnapshot()
        let resolution = try PriceResolver().resolve(rows: rows, pricing: pricing)
        return UsageSummary(
            period: period,
            tokenTotal: resolution.tokenTotal,
            knownAPIEquivalentUSD: resolution.knownUSD,
            unpricedTokens: resolution.unpricedTokens,
            exchangeRates: pricing.latestExchangeRates
        )
    }

    public func history(
        range: UsageHistoryRange,
        now: Date,
        calendar: Calendar,
        provider: Provider? = nil
    ) async throws -> UsageHistorySnapshot {
        let snapshots = try await history(
            ranges: [range],
            now: now,
            calendar: calendar,
            provider: provider
        )
        guard let snapshot = snapshots[range] else {
            throw UsageHistoryError.calendarArithmeticFailure
        }
        return snapshot
    }

    public func history(
        ranges: [UsageHistoryRange],
        now: Date,
        calendar: Calendar,
        provider: Provider? = nil
    ) async throws -> [UsageHistoryRange: UsageHistorySnapshot] {
        let requestedRanges = Set(ranges)
        guard !requestedRanges.isEmpty else { return [:] }
        guard let today = calendar.dateInterval(of: .day, for: now) else {
            throw UsageHistoryError.calendarArithmeticFailure
        }

        var intervalsByRange: [UsageHistoryRange: HistoryIntervals] = [:]
        for range in requestedRanges {
            intervalsByRange[range] = try historyIntervals(
                range: range,
                today: today,
                calendar: calendar
            )
        }
        guard let queryStart = intervalsByRange.values.map(\.previous.start).min() else {
            throw UsageHistoryError.calendarArithmeticFailure
        }

        let queryInterval = DateInterval(start: queryStart, end: today.end)
        let queriedRows = try await ledger.usageRows(in: queryInterval, calendar: calendar)
        let rows = queriedRows.filter { provider == nil || $0.provider == provider }
        let pricing = try await ledger.pricingSnapshot()
        let priceResolver = try PriceResolver(pricing: pricing)

        let hourlyCoverageStart = try await ledger.hourlyUsageCoverageStart()
        let hourlyRows: [HourlyUsageRow]
        if hourlyCoverageStart != nil {
            guard let hourlyQueryStart = intervalsByRange.values.map(\.current.start).min() else {
                throw UsageHistoryError.calendarArithmeticFailure
            }
            let queriedHourlyRows = try await ledger.hourlyUsageRows(
                in: DateInterval(start: hourlyQueryStart, end: today.end),
                calendar: calendar
            )
            hourlyRows = queriedHourlyRows.filter { provider == nil || $0.provider == provider }
        } else {
            hourlyRows = []
        }
        let activityCoverageStart = try await ledger.activitySliceCoverageStart()
        let activityRows: [ActivitySliceRow]
        if activityCoverageStart != nil {
            let queriedActivityRows = try await ledger.activitySliceRows(
                in: queryInterval,
                calendar: calendar
            )
            activityRows = queriedActivityRows.filter {
                provider == nil || $0.provider == provider
            }
        } else {
            activityRows = []
        }

        var snapshots: [UsageHistoryRange: UsageHistorySnapshot] = [:]
        for range in requestedRanges {
            guard let intervals = intervalsByRange[range] else {
                throw UsageHistoryError.calendarArithmeticFailure
            }
            let previousStartDay = LocalDay(
                date: intervals.previous.start,
                calendar: calendar
            ).value
            let currentStartDay = LocalDay(
                date: intervals.current.start,
                calendar: calendar
            ).value
            let rangeRows = rows.filter { $0.localDay.value >= previousStartDay }
            let currentRows = rangeRows.filter { $0.localDay.value >= currentStartDay }
            let previousRows = rangeRows.filter { $0.localDay.value < currentStartDay }
            let currentHourlyRows = hourlyRows.filter {
                $0.hourStart >= intervals.current.start
            }
            let rangeActivityRows = activityRows.filter {
                $0.sliceStart >= intervals.previous.start
            }
            let currentActivity = rangeActivityRows.filter {
                $0.sliceStart >= intervals.current.start
            }
            let previousActivity = rangeActivityRows.filter {
                $0.sliceStart < intervals.current.start
            }
            snapshots[range] = try historySnapshot(
                range: range,
                intervals: intervals,
                currentRows: currentRows,
                previousRows: previousRows,
                currentHourlyRows: currentHourlyRows,
                currentActivity: currentActivity,
                previousActivity: previousActivity,
                activityCoverageStart: activityCoverageStart,
                now: now,
                calendar: calendar,
                provider: provider,
                pricing: pricing,
                priceResolver: priceResolver
            )
        }
        return snapshots
    }

    private func historyIntervals(
        range: UsageHistoryRange,
        today: DateInterval,
        calendar: Calendar
    ) throws -> HistoryIntervals {
        guard let currentStart = calendar.date(
            byAdding: .day,
            value: -(range.dayCount - 1),
            to: today.start
        ), let previousStart = calendar.date(
            byAdding: .day,
            value: -range.dayCount,
            to: currentStart
        ) else {
            throw UsageHistoryError.calendarArithmeticFailure
        }
        return HistoryIntervals(
            current: DateInterval(start: currentStart, end: today.end),
            previous: DateInterval(start: previousStart, end: currentStart)
        )
    }

    private func historySnapshot(
        range: UsageHistoryRange,
        intervals: HistoryIntervals,
        currentRows: [DailyUsageRow],
        previousRows: [DailyUsageRow],
        currentHourlyRows: [HourlyUsageRow],
        currentActivity: [ActivitySliceRow],
        previousActivity: [ActivitySliceRow],
        activityCoverageStart: Date?,
        now: Date,
        calendar: Calendar,
        provider: Provider?,
        pricing: PricingSnapshot,
        priceResolver: PriceResolver
    ) throws -> UsageHistorySnapshot {
        let breakdown = try usageBreakdown(
            rows: currentRows,
            pricing: pricing,
            priceResolver: priceResolver
        )
        let previousTotal = try tokenTotal(in: previousRows)
        let delta = breakdown.tokenTotal - previousTotal
        let percentChange: Decimal? = if previousTotal == 0 {
            nil
        } else {
            Decimal(delta) * 100 / Decimal(previousTotal)
        }

        let points = if range == .today {
            try hourlyPoints(
                rows: currentHourlyRows,
                dailyRows: currentRows,
                interval: intervals.current,
                calendar: calendar,
                pricing: pricing,
                priceResolver: priceResolver
            )
        } else {
            try dailyPoints(
                rows: currentRows,
                interval: intervals.current,
                calendar: calendar,
                pricing: pricing,
                priceResolver: priceResolver
            )
        }

        let workPatterns: WorkPatternSnapshot? = if let activityCoverageStart {
            try WorkPatternCalculator().make(
                currentRows: currentHourlyRows,
                currentActivity: currentActivity,
                previousActivity: previousActivity,
                currentInterval: intervals.current,
                previousInterval: intervals.previous,
                coverageStart: activityCoverageStart,
                now: now,
                calendar: calendar
            )
        } else {
            nil
        }

        return UsageHistorySnapshot(
            range: range,
            provider: provider,
            currentInterval: intervals.current,
            previousInterval: intervals.previous,
            points: points,
            comparison: UsageComparison(
                currentTokenTotal: breakdown.tokenTotal,
                previousTokenTotal: previousTotal,
                tokenDelta: delta,
                percentChange: percentChange
            ),
            breakdown: breakdown,
            workPatterns: workPatterns
        )
    }

    private func hourlyPoints(
        rows: [HourlyUsageRow],
        dailyRows: [DailyUsageRow],
        interval: DateInterval,
        calendar: Calendar,
        pricing: PricingSnapshot,
        priceResolver: PriceResolver
    ) throws -> [UsageHistoryPoint] {
        var rowsByHour = Dictionary(grouping: rows, by: \.hourStart)
        var recordedTotals: [UsageRowKey: Int64] = [:]
        for row in rows {
            let key = UsageRowKey(row)
            recordedTotals[key] = try checkedAdd(recordedTotals[key, default: 0], row.quantity)
        }

        for dailyRow in dailyRows {
            let key = UsageRowKey(dailyRow)
            let recorded = recordedTotals[key, default: 0]
            guard recorded <= dailyRow.quantity else {
                throw UsageHistoryError.negativeQuantity
            }
            let baseline = dailyRow.quantity - recorded
            guard baseline > 0 else { continue }
            rowsByHour[interval.start, default: []].append(HourlyUsageRow(
                hourStart: interval.start,
                localDay: dailyRow.localDay,
                provider: dailyRow.provider,
                observedModelID: dailyRow.observedModelID,
                metric: dailyRow.metric,
                aggregation: dailyRow.aggregation,
                quantity: baseline
            ))
        }

        var points: [UsageHistoryPoint] = []
        var hourStart = interval.start
        while hourStart < interval.end {
            let hourRows = rowsByHour[hourStart, default: []].map(\.dailyRow)
            let breakdown = hourRows.isEmpty
                ? nil
                : try usageBreakdown(
                    rows: hourRows,
                    pricing: pricing,
                    priceResolver: priceResolver
                )
            points.append(UsageHistoryPoint(
                localDay: LocalDay(date: hourStart, calendar: calendar),
                hourStart: hourStart,
                tokenTotal: breakdown?.tokenTotal ?? 0,
                breakdown: breakdown
            ))
            guard let next = calendar.date(byAdding: .hour, value: 1, to: hourStart) else {
                throw UsageHistoryError.calendarArithmeticFailure
            }
            hourStart = next
        }
        return points
    }

    private func dailyPoints(
        rows: [DailyUsageRow],
        interval: DateInterval,
        calendar: Calendar,
        pricing: PricingSnapshot,
        priceResolver: PriceResolver
    ) throws -> [UsageHistoryPoint] {
        let rowsByDay = Dictionary(grouping: rows, by: { $0.localDay.value })

        var points: [UsageHistoryPoint] = []
        var date = interval.start
        while date < interval.end {
            let day = LocalDay(date: date, calendar: calendar)
            let dayRows = rowsByDay[day.value] ?? []
            let breakdown = dayRows.isEmpty
                ? nil
                : try usageBreakdown(
                    rows: dayRows,
                    pricing: pricing,
                    priceResolver: priceResolver
                )
            points.append(UsageHistoryPoint(
                localDay: day,
                tokenTotal: breakdown?.tokenTotal ?? 0,
                breakdown: breakdown
            ))
            guard let next = calendar.date(byAdding: .day, value: 1, to: date) else {
                throw UsageHistoryError.calendarArithmeticFailure
            }
            date = next
        }
        return points
    }

    private func usageBreakdown(
        rows: [DailyUsageRow],
        pricing: PricingSnapshot,
        priceResolver: PriceResolver
    ) throws -> UsageBreakdown {
        let resolution = try priceResolver.resolve(rows: rows)
        return UsageBreakdown(
            tokenTotal: resolution.tokenTotal,
            knownAPIEquivalentUSD: resolution.knownUSD,
            unpricedTokens: resolution.unpricedTokens,
            exchangeRates: pricing.latestExchangeRates,
            providers: try providerBreakdown(rows),
            models: try modelBreakdown(rows),
            tokenTypes: try tokenTypeBreakdown(rows)
        )
    }

    private func providerBreakdown(
        _ rows: [DailyUsageRow]
    ) throws -> [ProviderUsageBreakdown] {
        var totals: [Provider: Int64] = [:]
        for row in rows where row.aggregation == .additive {
            totals[row.provider] = try checkedAdd(totals[row.provider, default: 0], row.quantity)
        }
        return totals.map(ProviderUsageBreakdown.init)
            .sorted {
                if $0.tokenTotal != $1.tokenTotal { return $0.tokenTotal > $1.tokenTotal }
                return $0.provider.rawValue < $1.provider.rawValue
            }
    }

    private func modelBreakdown(
        _ rows: [DailyUsageRow]
    ) throws -> [ModelUsageBreakdown] {
        var totals: [ModelBreakdownKey: Int64] = [:]
        for row in rows where row.aggregation == .additive {
            let key = ModelBreakdownKey(provider: row.provider, observedModelID: row.observedModelID)
            totals[key] = try checkedAdd(totals[key, default: 0], row.quantity)
        }
        return totals.map {
            ModelUsageBreakdown(
                provider: $0.key.provider,
                observedModelID: $0.key.observedModelID,
                tokenTotal: $0.value
            )
        }.sorted {
            if $0.tokenTotal != $1.tokenTotal { return $0.tokenTotal > $1.tokenTotal }
            if $0.provider != $1.provider { return $0.provider.rawValue < $1.provider.rawValue }
            return $0.observedModelID < $1.observedModelID
        }
    }

    private func tokenTypeBreakdown(
        _ rows: [DailyUsageRow]
    ) throws -> [TokenTypeUsageBreakdown] {
        var totals: [UsageTokenCategory: Int64] = [:]
        for row in rows where row.aggregation == .additive {
            guard let category = row.metric.tokenCategory else { continue }
            totals[category] = try checkedAdd(totals[category, default: 0], row.quantity)
        }
        return UsageTokenCategory.allCases.map {
            TokenTypeUsageBreakdown(category: $0, tokenTotal: totals[$0, default: 0])
        }
    }

    private func tokenTotal(in rows: [DailyUsageRow]) throws -> Int64 {
        try rows.reduce(into: Int64.zero) { total, row in
            guard row.aggregation == .additive else { return }
            total = try checkedAdd(total, row.quantity)
        }
    }

    private func checkedAdd(_ lhs: Int64, _ rhs: Int64) throws -> Int64 {
        guard rhs >= 0 else { throw UsageHistoryError.negativeQuantity }
        let (result, overflow) = lhs.addingReportingOverflow(rhs)
        guard !overflow else { throw UsageHistoryError.tokenTotalOverflow }
        return result
    }
}

private struct ModelBreakdownKey: Hashable {
    let provider: Provider
    let observedModelID: String
}

private struct HistoryIntervals {
    let current: DateInterval
    let previous: DateInterval
}

private struct UsageRowKey: Hashable {
    let provider: Provider
    let observedModelID: String
    let metric: UsageMetric

    init(_ row: DailyUsageRow) {
        provider = row.provider
        observedModelID = row.observedModelID
        metric = row.metric
    }

    init(_ row: HourlyUsageRow) {
        provider = row.provider
        observedModelID = row.observedModelID
        metric = row.metric
    }
}

private extension HourlyUsageRow {
    var dailyRow: DailyUsageRow {
        DailyUsageRow(
            localDay: localDay,
            provider: provider,
            observedModelID: observedModelID,
            metric: metric,
            aggregation: aggregation,
            quantity: quantity
        )
    }
}

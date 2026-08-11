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
        guard let today = calendar.dateInterval(of: .day, for: now),
              let currentStart = calendar.date(
                  byAdding: .day,
                  value: -(range.dayCount - 1),
                  to: today.start
              ),
              let previousStart = calendar.date(
                  byAdding: .day,
                  value: -range.dayCount,
                  to: currentStart
              ) else {
            throw UsageHistoryError.calendarArithmeticFailure
        }

        let currentInterval = DateInterval(start: currentStart, end: today.end)
        let previousInterval = DateInterval(start: previousStart, end: currentStart)
        let queryInterval = DateInterval(start: previousStart, end: today.end)
        let queriedRows = try await ledger.usageRows(in: queryInterval, calendar: calendar)
        let rows = queriedRows.filter { provider == nil || $0.provider == provider }
        let currentStartDay = LocalDay(date: currentStart, calendar: calendar).value
        let currentRows = rows.filter { $0.localDay.value >= currentStartDay }
        let previousRows = rows.filter { $0.localDay.value < currentStartDay }
        let pricing = try await ledger.pricingSnapshot()
        let resolution = try PriceResolver().resolve(rows: currentRows, pricing: pricing)
        let previousTotal = try tokenTotal(in: previousRows)
        let delta = resolution.tokenTotal - previousTotal
        let percentChange: Decimal? = if previousTotal == 0 {
            nil
        } else {
            Decimal(delta) * 100 / Decimal(previousTotal)
        }

        return UsageHistorySnapshot(
            range: range,
            provider: provider,
            currentInterval: currentInterval,
            previousInterval: previousInterval,
            points: try dailyPoints(
                rows: currentRows,
                interval: currentInterval,
                calendar: calendar
            ),
            comparison: UsageComparison(
                currentTokenTotal: resolution.tokenTotal,
                previousTokenTotal: previousTotal,
                tokenDelta: delta,
                percentChange: percentChange
            ),
            breakdown: UsageBreakdown(
                tokenTotal: resolution.tokenTotal,
                knownAPIEquivalentUSD: resolution.knownUSD,
                unpricedTokens: resolution.unpricedTokens,
                exchangeRates: pricing.latestExchangeRates,
                providers: try providerBreakdown(currentRows),
                models: try modelBreakdown(currentRows),
                tokenTypes: try tokenTypeBreakdown(currentRows)
            )
        )
    }

    private func dailyPoints(
        rows: [DailyUsageRow],
        interval: DateInterval,
        calendar: Calendar
    ) throws -> [UsageHistoryPoint] {
        var totals: [String: Int64] = [:]
        for row in rows where row.aggregation == .additive {
            totals[row.localDay.value] = try checkedAdd(
                totals[row.localDay.value, default: 0],
                row.quantity
            )
        }

        var points: [UsageHistoryPoint] = []
        var date = interval.start
        while date < interval.end {
            let day = LocalDay(date: date, calendar: calendar)
            points.append(UsageHistoryPoint(
                localDay: day,
                tokenTotal: totals[day.value, default: 0]
            ))
            guard let next = calendar.date(byAdding: .day, value: 1, to: date) else {
                throw UsageHistoryError.calendarArithmeticFailure
            }
            date = next
        }
        return points
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

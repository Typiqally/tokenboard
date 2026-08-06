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
            unpricedTokens: resolution.unpricedTokens
        )
    }
}

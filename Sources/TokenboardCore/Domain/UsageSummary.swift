import Foundation

public struct UsageSummary: Equatable, Sendable {
    public let tokenScope: UsageTokenScope
    public let allTokenUnpricedTokens: Int64
    public let period: CalendarPeriod
    public let tokenTotal: Int64
    public let knownAPIEquivalentUSD: Decimal
    public let unpricedTokens: Int64
    public let unpricedUsage: [UnpricedUsageGroup]
    public let exchangeRates: ExchangeRateSnapshot?

    public init(
        period: CalendarPeriod,
        tokenTotal: Int64,
        knownAPIEquivalentUSD: Decimal,
        unpricedTokens: Int64,
        unpricedUsage: [UnpricedUsageGroup] = [],
        exchangeRates: ExchangeRateSnapshot? = nil,
        tokenScope: UsageTokenScope = .all,
        allTokenUnpricedTokens: Int64? = nil
    ) {
        self.tokenScope = tokenScope
        self.allTokenUnpricedTokens = allTokenUnpricedTokens ?? unpricedTokens
        self.period = period
        self.tokenTotal = tokenTotal
        self.knownAPIEquivalentUSD = knownAPIEquivalentUSD
        self.unpricedTokens = unpricedTokens
        self.unpricedUsage = unpricedUsage
        self.exchangeRates = exchangeRates
    }
}

import Foundation

public struct UsageSummary: Equatable, Sendable {
    public let period: CalendarPeriod
    public let tokenTotal: Int64
    public let knownAPIEquivalentUSD: Decimal
    public let unpricedTokens: Int64
    public let exchangeRates: ExchangeRateSnapshot?

    public init(
        period: CalendarPeriod,
        tokenTotal: Int64,
        knownAPIEquivalentUSD: Decimal,
        unpricedTokens: Int64,
        exchangeRates: ExchangeRateSnapshot? = nil
    ) {
        self.period = period
        self.tokenTotal = tokenTotal
        self.knownAPIEquivalentUSD = knownAPIEquivalentUSD
        self.unpricedTokens = unpricedTokens
        self.exchangeRates = exchangeRates
    }
}

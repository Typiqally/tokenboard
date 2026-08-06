import Foundation

public struct UsageSummary: Equatable, Sendable {
    public let period: CalendarPeriod
    public let tokenTotal: Int64
    public let knownAPIEquivalentUSD: Decimal
    public let unpricedTokens: Int64

    public init(
        period: CalendarPeriod,
        tokenTotal: Int64,
        knownAPIEquivalentUSD: Decimal,
        unpricedTokens: Int64
    ) {
        self.period = period
        self.tokenTotal = tokenTotal
        self.knownAPIEquivalentUSD = knownAPIEquivalentUSD
        self.unpricedTokens = unpricedTokens
    }
}

import Foundation

public enum UsageHistoryRange: Int, CaseIterable, Codable, Sendable {
    case sevenDays = 7
    case thirtyDays = 30
    case ninetyDays = 90

    public var dayCount: Int { rawValue }
}

public enum UsageTokenCategory: String, CaseIterable, Codable, Sendable {
    case input
    case cache
    case output
}

public struct UsageHistoryPoint: Equatable, Sendable {
    public let localDay: LocalDay
    public let tokenTotal: Int64
    public let breakdown: UsageBreakdown?

    public init(
        localDay: LocalDay,
        tokenTotal: Int64,
        breakdown: UsageBreakdown? = nil
    ) {
        self.localDay = localDay
        self.tokenTotal = tokenTotal
        self.breakdown = breakdown
    }
}

public struct UsageComparison: Equatable, Sendable {
    public let currentTokenTotal: Int64
    public let previousTokenTotal: Int64
    public let tokenDelta: Int64
    public let percentChange: Decimal?

    public init(
        currentTokenTotal: Int64,
        previousTokenTotal: Int64,
        tokenDelta: Int64,
        percentChange: Decimal?
    ) {
        self.currentTokenTotal = currentTokenTotal
        self.previousTokenTotal = previousTokenTotal
        self.tokenDelta = tokenDelta
        self.percentChange = percentChange
    }
}

public struct ProviderUsageBreakdown: Equatable, Sendable {
    public let provider: Provider
    public let tokenTotal: Int64

    public init(provider: Provider, tokenTotal: Int64) {
        self.provider = provider
        self.tokenTotal = tokenTotal
    }
}

public struct ModelUsageBreakdown: Equatable, Sendable {
    public let provider: Provider
    public let observedModelID: String
    public let tokenTotal: Int64

    public init(provider: Provider, observedModelID: String, tokenTotal: Int64) {
        self.provider = provider
        self.observedModelID = observedModelID
        self.tokenTotal = tokenTotal
    }
}

public struct TokenTypeUsageBreakdown: Equatable, Sendable {
    public let category: UsageTokenCategory
    public let tokenTotal: Int64

    public init(category: UsageTokenCategory, tokenTotal: Int64) {
        self.category = category
        self.tokenTotal = tokenTotal
    }
}

public struct UsageBreakdown: Equatable, Sendable {
    public let tokenTotal: Int64
    public let knownAPIEquivalentUSD: Decimal
    public let unpricedTokens: Int64
    public let exchangeRates: ExchangeRateSnapshot?
    public let providers: [ProviderUsageBreakdown]
    public let models: [ModelUsageBreakdown]
    public let tokenTypes: [TokenTypeUsageBreakdown]

    public init(
        tokenTotal: Int64,
        knownAPIEquivalentUSD: Decimal,
        unpricedTokens: Int64,
        exchangeRates: ExchangeRateSnapshot?,
        providers: [ProviderUsageBreakdown],
        models: [ModelUsageBreakdown],
        tokenTypes: [TokenTypeUsageBreakdown]
    ) {
        self.tokenTotal = tokenTotal
        self.knownAPIEquivalentUSD = knownAPIEquivalentUSD
        self.unpricedTokens = unpricedTokens
        self.exchangeRates = exchangeRates
        self.providers = providers
        self.models = models
        self.tokenTypes = tokenTypes
    }
}

public struct UsageHistorySnapshot: Equatable, Sendable {
    public let range: UsageHistoryRange
    public let provider: Provider?
    public let currentInterval: DateInterval
    public let previousInterval: DateInterval
    public let points: [UsageHistoryPoint]
    public let comparison: UsageComparison
    public let breakdown: UsageBreakdown

    public init(
        range: UsageHistoryRange,
        provider: Provider?,
        currentInterval: DateInterval,
        previousInterval: DateInterval,
        points: [UsageHistoryPoint],
        comparison: UsageComparison,
        breakdown: UsageBreakdown
    ) {
        self.range = range
        self.provider = provider
        self.currentInterval = currentInterval
        self.previousInterval = previousInterval
        self.points = points
        self.comparison = comparison
        self.breakdown = breakdown
    }
}

public enum UsageHistoryError: Error, Equatable, Sendable {
    case calendarArithmeticFailure
    case tokenTotalOverflow
    case negativeQuantity
}

extension UsageMetric {
    public var tokenCategory: UsageTokenCategory? {
        switch self {
        case .inputUncached, .inputUnclassified:
            .input
        case .inputCacheRead, .inputCacheWrite, .inputCacheWrite5m, .inputCacheWrite1h:
            .cache
        case .output:
            .output
        case .detailReasoningOutput:
            nil
        }
    }
}

import Foundation

public struct DailyUsageRow: Equatable, Sendable {
    public let localDay: LocalDay
    public let provider: Provider
    public let observedModelID: String
    public let metric: UsageMetric
    public let aggregation: MetricAggregation
    public let quantity: Int64

    public init(
        localDay: LocalDay,
        provider: Provider,
        observedModelID: String,
        metric: UsageMetric,
        aggregation: MetricAggregation,
        quantity: Int64
    ) {
        self.localDay = localDay
        self.provider = provider
        self.observedModelID = observedModelID
        self.metric = metric
        self.aggregation = aggregation
        self.quantity = quantity
    }
}

public struct HourlyUsageRow: Equatable, Sendable {
    public let hourStart: Date
    public let localDay: LocalDay
    public let provider: Provider
    public let observedModelID: String
    public let metric: UsageMetric
    public let aggregation: MetricAggregation
    public let quantity: Int64

    public init(
        hourStart: Date,
        localDay: LocalDay,
        provider: Provider,
        observedModelID: String,
        metric: UsageMetric,
        aggregation: MetricAggregation,
        quantity: Int64
    ) {
        self.hourStart = hourStart
        self.localDay = localDay
        self.provider = provider
        self.observedModelID = observedModelID
        self.metric = metric
        self.aggregation = aggregation
        self.quantity = quantity
    }
}

public struct SkippedRecord: Equatable, Sendable {
    public let sourceFingerprint: String
    public let byteOffset: Int64
    public let recordHash: String
    public let parserVersion: Int
    public let reason: String

    public init(
        sourceFingerprint: String,
        byteOffset: Int64,
        recordHash: String,
        parserVersion: Int,
        reason: String
    ) {
        self.sourceFingerprint = sourceFingerprint
        self.byteOffset = byteOffset
        self.recordHash = recordHash
        self.parserVersion = parserVersion
        self.reason = reason
    }
}

public protocol LedgerStore: Sendable {
    func migrate() async throws
    func commit(
        _ usage: [NormalizedUsage],
        skipped: [SkippedRecord],
        checkpoint: SourceCheckpoint,
        calendar: Calendar
    ) async throws
    func usageRows(in interval: DateInterval?, calendar: Calendar) async throws -> [DailyUsageRow]
    func lifetimeAdditiveTokenTotal() async throws -> Int64
    func hourlyUsageRows(
        in interval: DateInterval?,
        calendar: Calendar
    ) async throws -> [HourlyUsageRow]
    func hourlyUsageCoverageStart() async throws -> Date?
    func checkpoint(for fingerprint: String) async throws -> SourceCheckpoint?
    func sourceFingerprint(provider: Provider, stableID: String) async throws -> String
    func recordIdentityHash(_ value: String) async throws -> String
    func pricingSnapshot() async throws -> PricingSnapshot
    func latestAppliedPricingCatalogJSON() async throws -> Data?
    func applyPricingCatalog(
        _ catalog: ValidatedPricingCatalog,
        canonicalJSON: Data,
        origin: String,
        validationSummary: String
    ) async throws
}

public extension LedgerStore {
    func lifetimeAdditiveTokenTotal() async throws -> Int64 {
        var total: Int64 = 0
        for row in try await usageRows(in: nil, calendar: .current)
            where row.aggregation == .additive {
            let (sum, overflow) = total.addingReportingOverflow(row.quantity)
            guard !overflow else { throw LedgerError.quantityOverflow }
            total = sum
        }
        return total
    }

    func hourlyUsageRows(
        in interval: DateInterval?,
        calendar: Calendar
    ) async throws -> [HourlyUsageRow] {
        []
    }

    func hourlyUsageCoverageStart() async throws -> Date? {
        try await hourlyUsageRows(in: nil, calendar: .current).map(\.hourStart).min()
    }
}

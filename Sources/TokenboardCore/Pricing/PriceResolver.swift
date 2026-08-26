import Foundation

public struct PriceResolution: Equatable, Sendable {
    public let tokenTotal: Int64
    public let knownUSD: Decimal
    public let unpricedTokens: Int64

    public init(tokenTotal: Int64, knownUSD: Decimal, unpricedTokens: Int64) {
        self.tokenTotal = tokenTotal
        self.knownUSD = knownUSD
        self.unpricedTokens = unpricedTokens
    }
}

public enum UnpricedUsageReason: String, Equatable, Hashable, Sendable {
    case opaqueModel = "opaque_model"
    case missingAlias = "missing_alias"
    case missingRate = "missing_rate"
}

public struct UnpricedUsageGroup: Equatable, Identifiable, Sendable {
    public let provider: Provider
    public let observedModelID: String
    public let canonicalModelID: String?
    public let reason: UnpricedUsageReason
    public let tokenCount: Int64
    public let firstObservedDay: String
    public let lastObservedDay: String

    public var id: String {
        [
            provider.rawValue,
            observedModelID,
            canonicalModelID ?? "",
            reason.rawValue
        ].joined(separator: "/")
    }

    public init(
        provider: Provider,
        observedModelID: String,
        canonicalModelID: String?,
        reason: UnpricedUsageReason,
        tokenCount: Int64,
        firstObservedDay: String,
        lastObservedDay: String
    ) {
        self.provider = provider
        self.observedModelID = observedModelID
        self.canonicalModelID = canonicalModelID
        self.reason = reason
        self.tokenCount = tokenCount
        self.firstObservedDay = firstObservedDay
        self.lastObservedDay = lastObservedDay
    }
}

public enum PriceResolverError: Error, Equatable, Sendable {
    case negativeQuantity
    case tokenTotalOverflow
    case unpricedTokensOverflow
    case duplicateAliasEffectiveStart(
        provider: Provider,
        observedModelID: String,
        effectiveFrom: String
    )
    case duplicateRateEffectiveStart(
        provider: Provider,
        canonicalModelID: String,
        metric: UsageMetric,
        effectiveFrom: String
    )
    case invalidEffectiveDate(String)
    case invalidEffectiveInterval(from: String, to: String)
    case overlappingAliasIntervals(
        provider: Provider,
        observedModelID: String,
        earlierEffectiveFrom: String,
        laterEffectiveFrom: String
    )
    case overlappingRateIntervals(
        provider: Provider,
        canonicalModelID: String,
        metric: UsageMetric,
        earlierEffectiveFrom: String,
        laterEffectiveFrom: String
    )
    case decimalArithmeticFailure
}

public struct PriceResolver: Sendable {
    public init() {}

    public func resolve(
        rows: [DailyUsageRow],
        pricing: PricingSnapshot
    ) throws -> PriceResolution {
        try analyze(rows: rows, pricing: pricing).resolution
    }

    public func unpricedUsage(
        rows: [DailyUsageRow],
        pricing: PricingSnapshot
    ) throws -> [UnpricedUsageGroup] {
        try analyze(rows: rows, pricing: pricing).unpricedUsage
    }

    private func analyze(
        rows: [DailyUsageRow],
        pricing: PricingSnapshot
    ) throws -> (resolution: PriceResolution, unpricedUsage: [UnpricedUsageGroup]) {
        let aliases = try indexedAliases(pricing.aliases)
        let rates = try indexedRates(pricing.rates)
        var tokenTotal: Int64 = 0
        var knownUSD = Decimal.zero
        var unpricedTokens: Int64 = 0
        var groups: [UnpricedGroupKey: UnpricedAccumulator] = [:]

        for row in rows where row.aggregation == .additive {
            guard row.quantity >= 0 else { throw PriceResolverError.negativeQuantity }
            tokenTotal = try checkedAdd(
                tokenTotal,
                row.quantity,
                overflow: .tokenTotalOverflow
            )

            guard !ModelIdentifierPolicy.isOpaqueUnknown(row.observedModelID) else {
                unpricedTokens = try checkedAdd(
                    unpricedTokens,
                    row.quantity,
                    overflow: .unpricedTokensOverflow
                )
                try accumulate(
                    row,
                    canonicalModelID: nil,
                    reason: .opaqueModel,
                    into: &groups
                )
                continue
            }

            let aliasKey = AliasKey(provider: row.provider, observedModelID: row.observedModelID)
            guard let alias = effectiveRecord(
                in: aliases[aliasKey] ?? [],
                on: row.localDay.value
            ) else {
                unpricedTokens = try checkedAdd(
                    unpricedTokens,
                    row.quantity,
                    overflow: .unpricedTokensOverflow
                )
                try accumulate(
                    row,
                    canonicalModelID: nil,
                    reason: .missingAlias,
                    into: &groups
                )
                continue
            }
            guard let rate = effectiveRecord(
                in: rates[RateKey(
                        provider: row.provider,
                        canonicalModelID: alias.canonicalModelID,
                        metric: row.metric
                    )] ?? [],
                    on: row.localDay.value
            ) else {
                unpricedTokens = try checkedAdd(
                    unpricedTokens,
                    row.quantity,
                    overflow: .unpricedTokensOverflow
                )
                try accumulate(
                    row,
                    canonicalModelID: alias.canonicalModelID,
                    reason: .missingRate,
                    into: &groups
                )
                continue
            }

            let cost = try exactCost(quantity: row.quantity, usdPerMillion: rate.usdPerMillion)
            knownUSD = try exactAdd(knownUSD, cost)
        }

        let unpricedUsage = groups.map { key, value in
            UnpricedUsageGroup(
                provider: key.provider,
                observedModelID: key.observedModelID,
                canonicalModelID: key.canonicalModelID,
                reason: key.reason,
                tokenCount: value.tokenCount,
                firstObservedDay: value.firstObservedDay,
                lastObservedDay: value.lastObservedDay
            )
        }.sorted {
            if $0.tokenCount != $1.tokenCount { return $0.tokenCount > $1.tokenCount }
            return ($0.provider.rawValue, $0.observedModelID, $0.reason.rawValue)
                < ($1.provider.rawValue, $1.observedModelID, $1.reason.rawValue)
        }
        return (
            PriceResolution(
                tokenTotal: tokenTotal,
                knownUSD: knownUSD,
                unpricedTokens: unpricedTokens
            ),
            unpricedUsage
        )
    }

    private func accumulate(
        _ row: DailyUsageRow,
        canonicalModelID: String?,
        reason: UnpricedUsageReason,
        into groups: inout [UnpricedGroupKey: UnpricedAccumulator]
    ) throws {
        let key = UnpricedGroupKey(
            provider: row.provider,
            observedModelID: row.observedModelID,
            canonicalModelID: canonicalModelID,
            reason: reason
        )
        let day = row.localDay.value
        let existing = groups[key]
        groups[key] = UnpricedAccumulator(
            tokenCount: try checkedAdd(
                existing?.tokenCount ?? 0,
                row.quantity,
                overflow: .unpricedTokensOverflow
            ),
            firstObservedDay: min(existing?.firstObservedDay ?? day, day),
            lastObservedDay: max(existing?.lastObservedDay ?? day, day)
        )
    }

    private func indexedAliases(
        _ aliases: [StoredModelAlias]
    ) throws -> [AliasKey: [StoredModelAlias]] {
        var result: [AliasKey: [StoredModelAlias]] = [:]
        for alias in aliases {
            try validateInterval(from: alias.effectiveFrom, to: alias.effectiveTo)
            let key = AliasKey(provider: alias.provider, observedModelID: alias.observedModelID)
            if result[key, default: []].contains(where: { $0.effectiveFrom == alias.effectiveFrom }) {
                throw PriceResolverError.duplicateAliasEffectiveStart(
                    provider: alias.provider,
                    observedModelID: alias.observedModelID,
                    effectiveFrom: alias.effectiveFrom
                )
            }
            result[key, default: []].append(alias)
        }
        for key in result.keys {
            result[key]!.sort { $0.effectiveFrom < $1.effectiveFrom }
            let records = result[key]!
            for index in records.indices where index > records.startIndex {
                let earlier = records[records.index(before: index)]
                let later = records[index]
                if let end = earlier.effectiveTo, end > later.effectiveFrom {
                    throw PriceResolverError.overlappingAliasIntervals(
                        provider: earlier.provider,
                        observedModelID: earlier.observedModelID,
                        earlierEffectiveFrom: earlier.effectiveFrom,
                        laterEffectiveFrom: later.effectiveFrom
                    )
                }
            }
        }
        return result
    }

    private func indexedRates(
        _ rates: [StoredPriceRate]
    ) throws -> [RateKey: [StoredPriceRate]] {
        var result: [RateKey: [StoredPriceRate]] = [:]
        for rate in rates {
            try validateInterval(from: rate.effectiveFrom, to: rate.effectiveTo)
            let key = RateKey(
                provider: rate.provider,
                canonicalModelID: rate.canonicalModelID,
                metric: rate.metric
            )
            if result[key, default: []].contains(where: { $0.effectiveFrom == rate.effectiveFrom }) {
                throw PriceResolverError.duplicateRateEffectiveStart(
                    provider: rate.provider,
                    canonicalModelID: rate.canonicalModelID,
                    metric: rate.metric,
                    effectiveFrom: rate.effectiveFrom
                )
            }
            result[key, default: []].append(rate)
        }
        for key in result.keys {
            result[key]!.sort { $0.effectiveFrom < $1.effectiveFrom }
            let records = result[key]!
            for index in records.indices where index > records.startIndex {
                let earlier = records[records.index(before: index)]
                let later = records[index]
                if let end = earlier.effectiveTo, end > later.effectiveFrom {
                    throw PriceResolverError.overlappingRateIntervals(
                        provider: earlier.provider,
                        canonicalModelID: earlier.canonicalModelID,
                        metric: earlier.metric,
                        earlierEffectiveFrom: earlier.effectiveFrom,
                        laterEffectiveFrom: later.effectiveFrom
                    )
                }
            }
        }
        return result
    }

    private func validateInterval(from: String, to: String?) throws {
        try validateGregorianDay(from)
        if let to {
            try validateGregorianDay(to)
            guard to > from else {
                throw PriceResolverError.invalidEffectiveInterval(from: from, to: to)
            }
        }
    }

    private func validateGregorianDay(_ value: String) throws {
        guard GregorianDay.isValid(value) else {
            throw PriceResolverError.invalidEffectiveDate(value)
        }
    }

    private func effectiveRecord(
        in records: [StoredModelAlias],
        on day: String
    ) -> StoredModelAlias? {
        guard let candidate = records.last(where: { $0.effectiveFrom <= day }) else { return nil }
        guard candidate.effectiveTo.map({ day < $0 }) ?? true else { return nil }
        return candidate
    }

    private func effectiveRecord(
        in records: [StoredPriceRate],
        on day: String
    ) -> StoredPriceRate? {
        guard let candidate = records.last(where: { $0.effectiveFrom <= day }) else { return nil }
        guard candidate.effectiveTo.map({ day < $0 }) ?? true else { return nil }
        return candidate
    }

    private func checkedAdd(
        _ lhs: Int64,
        _ rhs: Int64,
        overflow error: PriceResolverError
    ) throws -> Int64 {
        let (result, overflowed) = lhs.addingReportingOverflow(rhs)
        guard !overflowed else { throw error }
        return result
    }

    private func exactCost(quantity: Int64, usdPerMillion: Decimal) throws -> Decimal {
        guard var quantityDecimal = Decimal(
            string: String(quantity),
            locale: Locale(identifier: "en_US_POSIX")
        ) else {
            throw PriceResolverError.decimalArithmeticFailure
        }
        var rate = usdPerMillion
        var product = Decimal.zero
        guard NSDecimalMultiply(&product, &quantityDecimal, &rate, .plain) == .noError else {
            throw PriceResolverError.decimalArithmeticFailure
        }

        guard var million = Decimal(
            string: "1000000",
            locale: Locale(identifier: "en_US_POSIX")
        ) else {
            throw PriceResolverError.decimalArithmeticFailure
        }
        var cost = Decimal.zero
        guard NSDecimalDivide(&cost, &product, &million, .plain) == .noError else {
            throw PriceResolverError.decimalArithmeticFailure
        }
        return cost
    }

    private func exactAdd(_ lhs: Decimal, _ rhs: Decimal) throws -> Decimal {
        var lhs = lhs
        var rhs = rhs
        var result = Decimal.zero
        guard NSDecimalAdd(&result, &lhs, &rhs, .plain) == .noError else {
            throw PriceResolverError.decimalArithmeticFailure
        }
        return result
    }
}

private struct AliasKey: Hashable {
    let provider: Provider
    let observedModelID: String

    static func == (lhs: AliasKey, rhs: AliasKey) -> Bool {
        lhs.provider == rhs.provider && lhs.observedModelID == rhs.observedModelID
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(provider.rawValue)
        hasher.combine(observedModelID)
    }
}

private struct RateKey: Hashable {
    let provider: Provider
    let canonicalModelID: String
    let metric: UsageMetric

    static func == (lhs: RateKey, rhs: RateKey) -> Bool {
        lhs.provider == rhs.provider
            && lhs.canonicalModelID == rhs.canonicalModelID
            && lhs.metric == rhs.metric
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(provider.rawValue)
        hasher.combine(canonicalModelID)
        hasher.combine(metric.rawValue)
    }
}

private struct UnpricedGroupKey: Hashable {
    let provider: Provider
    let observedModelID: String
    let canonicalModelID: String?
    let reason: UnpricedUsageReason
}

private struct UnpricedAccumulator {
    let tokenCount: Int64
    let firstObservedDay: String
    let lastObservedDay: String
}

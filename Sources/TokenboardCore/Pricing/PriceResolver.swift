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
    case decimalArithmeticFailure
}

public struct PriceResolver: Sendable {
    public init() {}

    public func resolve(
        rows: [DailyUsageRow],
        pricing: PricingSnapshot
    ) throws -> PriceResolution {
        let aliases = try indexedAliases(pricing.aliases)
        let rates = try indexedRates(pricing.rates)
        var tokenTotal: Int64 = 0
        var knownUSD = Decimal.zero
        var unpricedTokens: Int64 = 0

        for row in rows where row.aggregation == .additive {
            guard row.quantity >= 0 else { throw PriceResolverError.negativeQuantity }
            tokenTotal = try checkedAdd(
                tokenTotal,
                row.quantity,
                overflow: .tokenTotalOverflow
            )

            let aliasKey = AliasKey(provider: row.provider, observedModelID: row.observedModelID)
            guard let alias = effectiveRecord(in: aliases[aliasKey] ?? [], on: row.localDay.value),
                  let rate = effectiveRecord(
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
                continue
            }

            let cost = try exactCost(quantity: row.quantity, usdPerMillion: rate.usdPerMillion)
            knownUSD = try exactAdd(knownUSD, cost)
        }

        return PriceResolution(
            tokenTotal: tokenTotal,
            knownUSD: knownUSD,
            unpricedTokens: unpricedTokens
        )
    }

    private func indexedAliases(
        _ aliases: [StoredModelAlias]
    ) throws -> [AliasKey: [StoredModelAlias]] {
        var result: [AliasKey: [StoredModelAlias]] = [:]
        for alias in aliases {
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
        }
        return result
    }

    private func indexedRates(
        _ rates: [StoredPriceRate]
    ) throws -> [RateKey: [StoredPriceRate]] {
        var result: [RateKey: [StoredPriceRate]] = [:]
        for rate in rates {
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
        }
        return result
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

import Foundation

public struct PricingGap: Equatable, Hashable, Sendable {
    public let provider: Provider
    public let observedModelID: String
    public let metric: UsageMetric
    public let effectiveDate: String
    public let unpricedTokens: Int64

    public init(
        provider: Provider,
        observedModelID: String,
        metric: UsageMetric,
        effectiveDate: String,
        unpricedTokens: Int64
    ) {
        self.provider = provider
        self.observedModelID = observedModelID
        self.metric = metric
        self.effectiveDate = effectiveDate
        self.unpricedTokens = unpricedTokens
    }
}

public struct PricingAliasReview: Equatable, Sendable {
    public let provider: Provider
    public let observedModelID: String
    public let canonicalModelID: String
    public let effectiveFrom: String
    public let effectiveTo: String?

    public init(
        provider: Provider,
        observedModelID: String,
        canonicalModelID: String,
        effectiveFrom: String,
        effectiveTo: String?
    ) {
        self.provider = provider
        self.observedModelID = observedModelID
        self.canonicalModelID = canonicalModelID
        self.effectiveFrom = effectiveFrom
        self.effectiveTo = effectiveTo
    }
}

public struct PricingRateReview: Equatable, Sendable {
    public let provider: Provider
    public let canonicalModelID: String
    public let metric: UsageMetric
    public let usdPerMillion: Decimal
    public let effectiveFrom: String
    public let effectiveTo: String?
    public let provenanceURL: URL
    public let verifiedAt: String

    public init(
        provider: Provider,
        canonicalModelID: String,
        metric: UsageMetric,
        usdPerMillion: Decimal,
        effectiveFrom: String,
        effectiveTo: String?,
        provenanceURL: URL,
        verifiedAt: String
    ) {
        self.provider = provider
        self.canonicalModelID = canonicalModelID
        self.metric = metric
        self.usdPerMillion = usdPerMillion
        self.effectiveFrom = effectiveFrom
        self.effectiveTo = effectiveTo
        self.provenanceURL = provenanceURL
        self.verifiedAt = verifiedAt
    }
}

public struct PricingPreview: Equatable, Sendable {
    public let diff: CatalogDiff
    public let currentKnownUSD: Decimal
    public let candidateKnownUSD: Decimal
    public let newlyPricedTokens: Int64
    public let remainingUnpricedTokens: Int64
    public let provenanceURLs: [URL]
    public let unresolvedGaps: [PricingGap]
    public let reviewAliases: [PricingAliasReview]
    public let reviewRates: [PricingRateReview]

    public init(
        diff: CatalogDiff,
        currentKnownUSD: Decimal,
        candidateKnownUSD: Decimal,
        newlyPricedTokens: Int64,
        remainingUnpricedTokens: Int64,
        provenanceURLs: [URL],
        unresolvedGaps: [PricingGap],
        reviewAliases: [PricingAliasReview],
        reviewRates: [PricingRateReview]
    ) {
        self.diff = diff
        self.currentKnownUSD = currentKnownUSD
        self.candidateKnownUSD = candidateKnownUSD
        self.newlyPricedTokens = newlyPricedTokens
        self.remainingUnpricedTokens = remainingUnpricedTokens
        self.provenanceURLs = provenanceURLs
        self.unresolvedGaps = unresolvedGaps
        self.reviewAliases = reviewAliases
        self.reviewRates = reviewRates
    }

    public static func make(
        rows: [DailyUsageRow],
        currentPricing: PricingSnapshot,
        candidate: ValidatedPricingCatalog
    ) throws -> PricingPreview {
        let resolver = PriceResolver()
        let current = try resolver.resolve(rows: rows, pricing: currentPricing)
        let comparison = CatalogDiff.compare(candidate: candidate, against: currentPricing)
        let merge = merge(candidate: candidate, into: currentPricing, diff: comparison)

        var conflicts = comparison.conflicts
        let candidateResolution: PriceResolution
        let resolvedPricing: PricingSnapshot
        if conflicts.isEmpty {
            do {
                candidateResolution = try resolver.resolve(rows: rows, pricing: merge)
                resolvedPricing = merge
            } catch let error as PriceResolverError {
                conflicts.append(conflictDescription(error))
                candidateResolution = current
                resolvedPricing = currentPricing
            }
        } else {
            candidateResolution = current
            resolvedPricing = currentPricing
        }

        var newlyPriced: Int64 = 0
        var gaps: [PricingGapKey: Int64] = [:]
        for row in rows where row.aggregation == .additive {
            let before = try resolver.resolve(rows: [row], pricing: currentPricing)
            let after = try resolver.resolve(rows: [row], pricing: resolvedPricing)
            if before.unpricedTokens > 0, after.unpricedTokens == 0 {
                newlyPriced = try checkedAdd(newlyPriced, row.quantity)
            }
            if after.unpricedTokens > 0 {
                let key = PricingGapKey(
                    provider: row.provider,
                    observedModelID: row.observedModelID,
                    metric: row.metric,
                    effectiveDate: row.localDay.value
                )
                gaps[key] = try checkedAdd(gaps[key, default: 0], row.quantity)
            }
        }
        let unresolvedGaps = gaps.map { key, quantity in
            PricingGap(
                provider: key.provider,
                observedModelID: key.observedModelID,
                metric: key.metric,
                effectiveDate: key.effectiveDate,
                unpricedTokens: quantity
            )
        }.sorted {
            ($0.provider.rawValue, $0.observedModelID, $0.effectiveDate, $0.metric.rawValue)
                < ($1.provider.rawValue, $1.observedModelID, $1.effectiveDate, $1.metric.rawValue)
        }

        return PricingPreview(
            diff: CatalogDiff(
                modelsAdded: comparison.modelsAdded,
                aliasesAdded: comparison.aliasesAdded,
                ratesAdded: comparison.ratesAdded,
                conflicts: Array(Set(conflicts)).sorted()
            ),
            currentKnownUSD: current.knownUSD,
            candidateKnownUSD: candidateResolution.knownUSD,
            newlyPricedTokens: newlyPriced,
            remainingUnpricedTokens: candidateResolution.unpricedTokens,
            provenanceURLs: Array(Set(candidate.models.flatMap { model in
                model.rates.map(\.provenanceURL)
            })).sorted { $0.absoluteString < $1.absoluteString },
            unresolvedGaps: unresolvedGaps,
            reviewAliases: candidate.models.flatMap { model in
                model.aliases.map { alias in
                    PricingAliasReview(
                        provider: model.provider,
                        observedModelID: alias.observedModelID,
                        canonicalModelID: model.canonicalModelID,
                        effectiveFrom: alias.effectiveFrom,
                        effectiveTo: alias.effectiveTo
                    )
                }
            }.sorted {
                ($0.provider.rawValue, $0.observedModelID, $0.effectiveFrom, $0.canonicalModelID)
                    < ($1.provider.rawValue, $1.observedModelID, $1.effectiveFrom, $1.canonicalModelID)
            },
            reviewRates: candidate.models.flatMap { model in
                model.rates.flatMap { rate in
                    rate.prices.map { metric, price in
                        PricingRateReview(
                            provider: model.provider,
                            canonicalModelID: model.canonicalModelID,
                            metric: metric,
                            usdPerMillion: price,
                            effectiveFrom: rate.effectiveFrom,
                            effectiveTo: rate.effectiveTo,
                            provenanceURL: rate.provenanceURL,
                            verifiedAt: rate.verifiedAt
                        )
                    }
                }
            }.sorted {
                ($0.provider.rawValue, $0.canonicalModelID, $0.metric.rawValue, $0.effectiveFrom)
                    < ($1.provider.rawValue, $1.canonicalModelID, $1.metric.rawValue, $1.effectiveFrom)
            }
        )
    }

    private static func checkedAdd(_ lhs: Int64, _ rhs: Int64) throws -> Int64 {
        let (result, overflow) = lhs.addingReportingOverflow(rhs)
        guard !overflow else { throw PriceResolverError.unpricedTokensOverflow }
        return result
    }

    private static func merge(
        candidate: ValidatedPricingCatalog,
        into current: PricingSnapshot,
        diff: CatalogDiff
    ) -> PricingSnapshot {
        let conflicts = Set(diff.conflicts)
        var aliases = current.aliases
        var rates = current.rates

        for model in candidate.models {
            for alias in model.aliases {
                let label = "alias \(model.provider.rawValue)/\(alias.observedModelID)/\(alias.effectiveFrom)"
                guard !conflicts.contains(label) else { continue }
                let stored = StoredModelAlias(
                    provider: model.provider,
                    observedModelID: alias.observedModelID,
                    canonicalModelID: model.canonicalModelID,
                    effectiveFrom: alias.effectiveFrom,
                    effectiveTo: alias.effectiveTo
                )
                if !aliases.contains(stored) {
                    aliases.append(stored)
                }
            }

            for rate in model.rates {
                for (metric, price) in rate.prices {
                    let label = "rate \(model.provider.rawValue)/\(model.canonicalModelID)/\(metric.rawValue)/\(rate.effectiveFrom)"
                    guard !conflicts.contains(label) else { continue }
                    let stored = StoredPriceRate(
                        provider: model.provider,
                        canonicalModelID: model.canonicalModelID,
                        metric: metric,
                        usdPerMillion: price,
                        effectiveFrom: rate.effectiveFrom,
                        effectiveTo: rate.effectiveTo,
                        provenanceURL: rate.provenanceURL,
                        verifiedAt: rate.verifiedAt
                    )
                    if !rates.contains(stored) {
                        rates.append(stored)
                    }
                }
            }
        }

        var catalogIDs = current.catalogIDs
        if !catalogIDs.contains(candidate.catalogID) {
            catalogIDs.append(candidate.catalogID)
        }
        return PricingSnapshot(catalogIDs: catalogIDs, rates: rates, aliases: aliases)
    }

    private static func conflictDescription(_ error: PriceResolverError) -> String {
        switch error {
        case let .duplicateAliasEffectiveStart(provider, observedModelID, effectiveFrom):
            "alias \(provider.rawValue)/\(observedModelID)/\(effectiveFrom)"
        case let .duplicateRateEffectiveStart(provider, canonicalModelID, metric, effectiveFrom):
            "rate \(provider.rawValue)/\(canonicalModelID)/\(metric.rawValue)/\(effectiveFrom)"
        case let .overlappingAliasIntervals(provider, observedModelID, earlier, later):
            "alias interval \(provider.rawValue)/\(observedModelID)/\(earlier)-\(later)"
        case let .overlappingRateIntervals(provider, canonicalModelID, metric, earlier, later):
            "rate interval \(provider.rawValue)/\(canonicalModelID)/\(metric.rawValue)/\(earlier)-\(later)"
        case let .invalidEffectiveDate(value):
            "invalid effective date \(value)"
        case let .invalidEffectiveInterval(from, to):
            "invalid effective interval \(from)-\(to)"
        case .negativeQuantity:
            "negative usage quantity"
        case .tokenTotalOverflow:
            "token total overflow"
        case .unpricedTokensOverflow:
            "unpriced token total overflow"
        case .decimalArithmeticFailure:
            "decimal arithmetic failure"
        }
    }
}

private struct PricingGapKey: Hashable {
    let provider: Provider
    let observedModelID: String
    let metric: UsageMetric
    let effectiveDate: String
}

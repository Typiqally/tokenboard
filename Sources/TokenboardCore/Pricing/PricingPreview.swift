import Foundation

public struct PricingPreview: Equatable, Sendable {
    public let diff: CatalogDiff
    public let currentKnownUSD: Decimal
    public let candidateKnownUSD: Decimal
    public let newlyPricedTokens: Int64
    public let remainingUnpricedTokens: Int64
    public let provenanceURLs: [URL]

    public init(
        diff: CatalogDiff,
        currentKnownUSD: Decimal,
        candidateKnownUSD: Decimal,
        newlyPricedTokens: Int64,
        remainingUnpricedTokens: Int64,
        provenanceURLs: [URL]
    ) {
        self.diff = diff
        self.currentKnownUSD = currentKnownUSD
        self.candidateKnownUSD = candidateKnownUSD
        self.newlyPricedTokens = newlyPricedTokens
        self.remainingUnpricedTokens = remainingUnpricedTokens
        self.provenanceURLs = provenanceURLs
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
        if conflicts.isEmpty {
            do {
                candidateResolution = try resolver.resolve(rows: rows, pricing: merge)
            } catch let error as PriceResolverError {
                conflicts.append(conflictDescription(error))
                candidateResolution = current
            }
        } else {
            candidateResolution = current
        }

        let newlyPriced: Int64
        if candidateResolution.unpricedTokens <= current.unpricedTokens {
            newlyPriced = current.unpricedTokens - candidateResolution.unpricedTokens
        } else {
            newlyPriced = 0
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
            })).sorted { $0.absoluteString < $1.absoluteString }
        )
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

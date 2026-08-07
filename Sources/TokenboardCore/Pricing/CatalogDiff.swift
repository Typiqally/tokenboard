import Foundation

public struct StoredPriceRate: Equatable, Sendable {
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

public struct StoredModelAlias: Equatable, Sendable {
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

public struct ExchangeRateSnapshot: Equatable, Sendable {
    public let catalogID: String
    public let effectiveDate: String
    public let verifiedAt: String
    public let provenanceURL: URL
    public let rates: [DisplayCurrency: Decimal]

    public init(
        catalogID: String,
        effectiveDate: String,
        verifiedAt: String,
        provenanceURL: URL,
        rates: [DisplayCurrency: Decimal]
    ) {
        self.catalogID = catalogID
        self.effectiveDate = effectiveDate
        self.verifiedAt = verifiedAt
        self.provenanceURL = provenanceURL
        self.rates = rates
    }

    public init(catalogID: String, validated: ValidatedExchangeRateSnapshot) {
        self.init(
            catalogID: catalogID,
            effectiveDate: validated.effectiveDate,
            verifiedAt: validated.verifiedAt,
            provenanceURL: validated.provenanceURL,
            rates: validated.rates
        )
    }
}

public struct PricingSnapshot: Equatable, Sendable {
    public let catalogIDs: [String]
    public let rates: [StoredPriceRate]
    public let aliases: [StoredModelAlias]
    public let exchangeRateSnapshots: [ExchangeRateSnapshot]

    public init(
        catalogIDs: [String],
        rates: [StoredPriceRate],
        aliases: [StoredModelAlias],
        exchangeRateSnapshots: [ExchangeRateSnapshot] = []
    ) {
        self.catalogIDs = catalogIDs
        self.rates = rates
        self.aliases = aliases
        self.exchangeRateSnapshots = exchangeRateSnapshots
    }

    public var latestExchangeRates: ExchangeRateSnapshot? { exchangeRateSnapshots.last }
}

public struct CatalogDiff: Equatable, Sendable {
    public let modelsAdded: [String]
    public let aliasesAdded: Int
    public let ratesAdded: Int
    public let exchangeRatesChanged: [DisplayCurrency]
    public let conflicts: [String]

    public init(
        modelsAdded: [String],
        aliasesAdded: Int,
        ratesAdded: Int,
        exchangeRatesChanged: [DisplayCurrency] = [],
        conflicts: [String]
    ) {
        self.modelsAdded = modelsAdded
        self.aliasesAdded = aliasesAdded
        self.ratesAdded = ratesAdded
        self.exchangeRatesChanged = exchangeRatesChanged
        self.conflicts = conflicts
    }

    public static func compare(
        candidate: ValidatedPricingCatalog,
        against snapshot: PricingSnapshot
    ) -> CatalogDiff {
        let existingModels = Set(
            snapshot.rates.map { ModelIdentity(provider: $0.provider, canonicalModelID: $0.canonicalModelID) }
                + snapshot.aliases.map { ModelIdentity(provider: $0.provider, canonicalModelID: $0.canonicalModelID) }
        )
        var modelsAdded = Set<String>()
        var aliasesAdded = 0
        var ratesAdded = 0
        var conflicts: [String] = []

        for model in candidate.models {
            let identity = ModelIdentity(provider: model.provider, canonicalModelID: model.canonicalModelID)
            if !existingModels.contains(identity) {
                modelsAdded.insert("\(model.provider.rawValue)/\(model.canonicalModelID)")
            }
            for alias in model.aliases {
                let matches = snapshot.aliases.filter {
                    $0.provider == model.provider
                        && $0.observedModelID == alias.observedModelID
                        && $0.effectiveFrom == alias.effectiveFrom
                }
                if matches.isEmpty {
                    aliasesAdded += 1
                } else if !matches.contains(where: {
                    $0.canonicalModelID == model.canonicalModelID && $0.effectiveTo == alias.effectiveTo
                }) {
                    conflicts.append("alias \(model.provider.rawValue)/\(alias.observedModelID)/\(alias.effectiveFrom)")
                }
            }
            for rate in model.rates {
                for (metric, decimal) in rate.prices {
                    let matches = snapshot.rates.filter {
                        $0.provider == model.provider
                            && $0.canonicalModelID == model.canonicalModelID
                            && $0.metric == metric
                            && $0.effectiveFrom == rate.effectiveFrom
                    }
                    if matches.isEmpty {
                        ratesAdded += 1
                    } else if !matches.contains(where: {
                        $0.usdPerMillion == decimal
                            && $0.effectiveTo == rate.effectiveTo
                            && $0.provenanceURL == rate.provenanceURL
                            && $0.verifiedAt == rate.verifiedAt
                    }) {
                        conflicts.append(
                            "rate \(model.provider.rawValue)/\(model.canonicalModelID)/\(metric.rawValue)/\(rate.effectiveFrom)"
                        )
                    }
                }
            }
        }
        let exchangeRatesChanged: [DisplayCurrency]
        if let candidateRates = candidate.exchangeRates {
            let existing = snapshot.latestExchangeRates
            let metadataChanged = existing?.effectiveDate != candidateRates.effectiveDate
                || existing?.verifiedAt != candidateRates.verifiedAt
                || existing?.provenanceURL != candidateRates.provenanceURL
            exchangeRatesChanged = DisplayCurrency.allCases.filter {
                metadataChanged || existing?.rates[$0] != candidateRates.rates[$0]
            }
        } else {
            exchangeRatesChanged = []
        }
        return CatalogDiff(
            modelsAdded: modelsAdded.sorted(),
            aliasesAdded: aliasesAdded,
            ratesAdded: ratesAdded,
            exchangeRatesChanged: exchangeRatesChanged,
            conflicts: conflicts.sorted()
        )
    }
}

private struct ModelIdentity: Hashable {
    let provider: Provider
    let canonicalModelID: String
}

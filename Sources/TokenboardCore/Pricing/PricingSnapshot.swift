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

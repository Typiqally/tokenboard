import Foundation

public struct PricingCatalog: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let catalogID: String
    public let generatedAt: String
    public let origin: CatalogOrigin
    public var models: [CatalogModel]
    public let exchangeRates: CatalogExchangeRateSnapshot?

    public init(
        schemaVersion: Int,
        catalogID: String,
        generatedAt: String,
        origin: CatalogOrigin,
        models: [CatalogModel],
        exchangeRates: CatalogExchangeRateSnapshot? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.catalogID = catalogID
        self.generatedAt = generatedAt
        self.origin = origin
        self.models = models
        self.exchangeRates = exchangeRates
    }
}

public struct CatalogExchangeRateSnapshot: Codable, Equatable, Sendable {
    public let baseCurrency: String
    public let effectiveDate: String
    public let verifiedAt: String
    public let provenanceURL: String
    public let rates: [String: DecimalString]

    public init(
        baseCurrency: String,
        effectiveDate: String,
        verifiedAt: String,
        provenanceURL: String,
        rates: [String: DecimalString]
    ) {
        self.baseCurrency = baseCurrency
        self.effectiveDate = effectiveDate
        self.verifiedAt = verifiedAt
        self.provenanceURL = provenanceURL
        self.rates = rates
    }
}

public struct CatalogOrigin: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case tokenboardRepository = "tokenboard_repository"
        case officialResearch = "official_research"
    }

    public let kind: Kind
    public let url: String

    public init(kind: Kind, url: String) {
        self.kind = kind
        self.url = url
    }
}

public struct CatalogModel: Codable, Equatable, Sendable {
    public let provider: Provider
    public let canonicalModelID: String
    public let aliases: [CatalogAlias]
    public var rates: [CatalogRate]

    public init(
        provider: Provider,
        canonicalModelID: String,
        aliases: [CatalogAlias],
        rates: [CatalogRate]
    ) {
        self.provider = provider
        self.canonicalModelID = canonicalModelID
        self.aliases = aliases
        self.rates = rates
    }
}

public struct CatalogAlias: Codable, Equatable, Sendable {
    public let observedModelID: String
    public let effectiveFrom: String
    public let effectiveTo: String?

    public init(observedModelID: String, effectiveFrom: String, effectiveTo: String?) {
        self.observedModelID = observedModelID
        self.effectiveFrom = effectiveFrom
        self.effectiveTo = effectiveTo
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(observedModelID, forKey: .observedModelID)
        try container.encode(effectiveFrom, forKey: .effectiveFrom)
        if let effectiveTo {
            try container.encode(effectiveTo, forKey: .effectiveTo)
        } else {
            try container.encodeNil(forKey: .effectiveTo)
        }
    }

    private enum CodingKeys: String, CodingKey {
        case observedModelID
        case effectiveFrom
        case effectiveTo
    }
}

public struct CatalogRate: Codable, Equatable, Sendable {
    public let effectiveFrom: String
    public let effectiveTo: String?
    public let prices: [String: DecimalString]
    public let provenanceURL: String
    public let verifiedAt: String

    public init(
        effectiveFrom: String,
        effectiveTo: String?,
        prices: [String: DecimalString],
        provenanceURL: String,
        verifiedAt: String
    ) {
        self.effectiveFrom = effectiveFrom
        self.effectiveTo = effectiveTo
        self.prices = prices
        self.provenanceURL = provenanceURL
        self.verifiedAt = verifiedAt
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(effectiveFrom, forKey: .effectiveFrom)
        if let effectiveTo {
            try container.encode(effectiveTo, forKey: .effectiveTo)
        } else {
            try container.encodeNil(forKey: .effectiveTo)
        }
        try container.encode(prices, forKey: .prices)
        try container.encode(provenanceURL, forKey: .provenanceURL)
        try container.encode(verifiedAt, forKey: .verifiedAt)
    }

    private enum CodingKeys: String, CodingKey {
        case effectiveFrom
        case effectiveTo
        case prices
        case provenanceURL
        case verifiedAt
    }
}

public struct ValidatedPricingCatalog: Equatable, Sendable {
    public let schemaVersion: Int
    public let catalogID: String
    public let generatedAt: String
    public let origin: CatalogOrigin
    public let models: [ValidatedCatalogModel]
    public let exchangeRates: ValidatedExchangeRateSnapshot?
    public let canonicalJSON: Data

    init(
        schemaVersion: Int,
        catalogID: String,
        generatedAt: String,
        origin: CatalogOrigin,
        models: [ValidatedCatalogModel],
        exchangeRates: ValidatedExchangeRateSnapshot?,
        canonicalJSON: Data
    ) {
        self.schemaVersion = schemaVersion
        self.catalogID = catalogID
        self.generatedAt = generatedAt
        self.origin = origin
        self.models = models
        self.exchangeRates = exchangeRates
        self.canonicalJSON = canonicalJSON
    }
}

public struct ValidatedExchangeRateSnapshot: Equatable, Sendable {
    public let baseCurrency: DisplayCurrency
    public let effectiveDate: String
    public let verifiedAt: String
    public let provenanceURL: URL
    public let rates: [DisplayCurrency: Decimal]

    public init(
        baseCurrency: DisplayCurrency,
        effectiveDate: String,
        verifiedAt: String,
        provenanceURL: URL,
        rates: [DisplayCurrency: Decimal]
    ) {
        self.baseCurrency = baseCurrency
        self.effectiveDate = effectiveDate
        self.verifiedAt = verifiedAt
        self.provenanceURL = provenanceURL
        self.rates = rates
    }
}

public struct ValidatedCatalogModel: Equatable, Sendable {
    public let provider: Provider
    public let canonicalModelID: String
    public let aliases: [CatalogAlias]
    public let rates: [ValidatedCatalogRate]

    init(
        provider: Provider,
        canonicalModelID: String,
        aliases: [CatalogAlias],
        rates: [ValidatedCatalogRate]
    ) {
        self.provider = provider
        self.canonicalModelID = canonicalModelID
        self.aliases = aliases
        self.rates = rates
    }
}

public struct ValidatedCatalogRate: Equatable, Sendable {
    public let effectiveFrom: String
    public let effectiveTo: String?
    public let prices: [UsageMetric: Decimal]
    public let provenanceURL: URL
    public let verifiedAt: String

    init(
        effectiveFrom: String,
        effectiveTo: String?,
        prices: [UsageMetric: Decimal],
        provenanceURL: URL,
        verifiedAt: String
    ) {
        self.effectiveFrom = effectiveFrom
        self.effectiveTo = effectiveTo
        self.prices = prices
        self.provenanceURL = provenanceURL
        self.verifiedAt = verifiedAt
    }
}

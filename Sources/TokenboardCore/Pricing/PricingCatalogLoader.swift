import Foundation

public enum PricingCatalogLoadingError: Error, Equatable, Sendable {
    case documentTooLarge
    case documentTooDeep
    case duplicateObjectMember(String)
    case invalidJSON
    case invalidStructure(String)
}

public struct PricingCatalogLoader: Sendable {
    public init() {}

    public func load(_ data: Data) throws -> PricingCatalog {
        guard data.count <= 1_048_576 else {
            throw PricingCatalogLoadingError.documentTooLarge
        }
        var scanner = StrictJSONScanner(data: data, maximumContainerDepth: 16)
        try scanner.validate()

        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        } catch {
            throw PricingCatalogLoadingError.invalidJSON
        }
        try validateKeys(in: object)

        do {
            return try JSONDecoder().decode(PricingCatalog.self, from: data)
        } catch {
            throw error
        }
    }

    private func validateKeys(in root: Any) throws {
        let top = try object(root, named: "catalog")
        guard let schemaVersion = top["schemaVersion"] as? Int else {
            throw PricingCatalogLoadingError.invalidStructure("schemaVersion must be an integer")
        }
        if schemaVersion == 1 {
            try requireExactKeys(
                top,
                expected: ["schemaVersion", "catalogID", "generatedAt", "origin", "models"],
                named: "catalog"
            )
        } else {
            try requireExactKeys(
                top,
                expected: [
                    "schemaVersion", "catalogID", "generatedAt", "origin", "models", "exchangeRates"
                ],
                named: "catalog"
            )
            let exchangeRates = try object(top["exchangeRates"], named: "exchangeRates")
            try requireExactKeys(
                exchangeRates,
                expected: ["baseCurrency", "effectiveDate", "verifiedAt", "provenanceURL", "rates"],
                named: "exchangeRates"
            )
            _ = try object(exchangeRates["rates"], named: "exchangeRates.rates")
        }

        let origin = try object(top["origin"], named: "origin")
        try requireExactKeys(origin, expected: ["kind", "url"], named: "origin")

        guard let models = top["models"] as? [Any] else {
            throw PricingCatalogLoadingError.invalidStructure("models must be an array")
        }
        for modelValue in models {
            let model = try object(modelValue, named: "model")
            try requireExactKeys(
                model,
                expected: ["provider", "canonicalModelID", "aliases", "rates"],
                named: "model"
            )

            guard let aliases = model["aliases"] as? [Any] else {
                throw PricingCatalogLoadingError.invalidStructure("aliases must be an array")
            }
            for aliasValue in aliases {
                let alias = try object(aliasValue, named: "alias")
                try requireExactKeys(
                    alias,
                    expected: ["observedModelID", "effectiveFrom", "effectiveTo"],
                    named: "alias"
                )
            }

            guard let rates = model["rates"] as? [Any] else {
                throw PricingCatalogLoadingError.invalidStructure("rates must be an array")
            }
            for rateValue in rates {
                let rate = try object(rateValue, named: "rate")
                try requireExactKeys(
                    rate,
                    expected: ["effectiveFrom", "effectiveTo", "prices", "provenanceURL", "verifiedAt"],
                    named: "rate"
                )
                _ = try object(rate["prices"], named: "prices")
            }
        }
    }

    private func object(_ value: Any?, named name: String) throws -> [String: Any] {
        guard let value = value as? [String: Any] else {
            throw PricingCatalogLoadingError.invalidStructure("\(name) must be an object")
        }
        return value
    }

    private func requireExactKeys(
        _ object: [String: Any],
        expected: Set<String>,
        named name: String
    ) throws {
        guard Set(object.keys) == expected else {
            throw PricingCatalogLoadingError.invalidStructure("\(name) has missing or unknown keys")
        }
    }
}

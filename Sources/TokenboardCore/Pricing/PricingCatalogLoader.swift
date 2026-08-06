import Foundation

public enum PricingCatalogLoadingError: Error, Equatable, Sendable {
    case documentTooLarge
    case documentTooDeep
    case invalidJSON
    case invalidStructure(String)
}

public struct PricingCatalogLoader: Sendable {
    public init() {}

    public func load(_ data: Data) throws -> PricingCatalog {
        guard data.count <= 1_048_576 else {
            throw PricingCatalogLoadingError.documentTooLarge
        }

        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        } catch {
            throw PricingCatalogLoadingError.invalidJSON
        }
        try validateDepth(of: object, depth: 1)
        try validateKeys(in: object)

        do {
            return try JSONDecoder().decode(PricingCatalog.self, from: data)
        } catch {
            throw error
        }
    }

    private func validateDepth(of value: Any, depth: Int) throws {
        switch value {
        case let dictionary as [String: Any]:
            guard depth <= 16 else { throw PricingCatalogLoadingError.documentTooDeep }
            for child in dictionary.values {
                try validateDepth(of: child, depth: depth + 1)
            }
        case let array as [Any]:
            guard depth <= 16 else { throw PricingCatalogLoadingError.documentTooDeep }
            for child in array {
                try validateDepth(of: child, depth: depth + 1)
            }
        default:
            return
        }
    }

    private func validateKeys(in root: Any) throws {
        let top = try object(root, named: "catalog")
        try requireExactKeys(
            top,
            expected: ["schemaVersion", "catalogID", "generatedAt", "origin", "models"],
            named: "catalog"
        )

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

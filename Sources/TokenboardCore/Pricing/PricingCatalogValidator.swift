import Foundation

public enum PricingCatalogValidationError: Error, Equatable, Sendable {
    case unsupportedSchemaVersion(Int)
    case invalidIdentifier(String)
    case invalidGeneratedAt
    case invalidDate(String)
    case invalidInterval(String)
    case invalidURL(String)
    case invalidOrigin
    case invalidProvenance(provider: Provider)
    case duplicateModel(String)
    case duplicateEffectiveStart(String)
    case overlappingInterval(String)
    case invalidMetric(String)
    case missingRequiredMetric(String)
    case canonicalEncodingFailed
}

public struct PricingCatalogValidator: Sendable {
    public init() {}

    public func validate(_ catalog: PricingCatalog) throws -> ValidatedPricingCatalog {
        guard catalog.schemaVersion == 1 else {
            throw PricingCatalogValidationError.unsupportedSchemaVersion(catalog.schemaVersion)
        }
        try validateIdentifier(catalog.catalogID, label: "catalog ID")
        guard Self.isISO8601Timestamp(catalog.generatedAt) else {
            throw PricingCatalogValidationError.invalidGeneratedAt
        }
        do {
            try validateDate(String(catalog.generatedAt.prefix(10)))
        } catch {
            throw PricingCatalogValidationError.invalidGeneratedAt
        }
        try validateOrigin(catalog.origin)

        var modelKeys = Set<ModelKey>()
        var aliasIntervals: [AliasKey: [Interval]] = [:]
        var rateIntervals: [RateKey: [Interval]] = [:]
        var validatedModels: [ValidatedCatalogModel] = []

        for model in catalog.models {
            try validateIdentifier(model.canonicalModelID, label: "canonical model ID")
            let modelKey = ModelKey(provider: model.provider, canonicalModelID: model.canonicalModelID)
            guard modelKeys.insert(modelKey).inserted else {
                throw PricingCatalogValidationError.duplicateModel(model.canonicalModelID)
            }

            var aliases: [CatalogAlias] = []
            for alias in model.aliases {
                try validateIdentifier(alias.observedModelID, label: "observed model ID")
                try validateInterval(from: alias.effectiveFrom, to: alias.effectiveTo)
                aliasIntervals[
                    AliasKey(provider: model.provider, observedModelID: alias.observedModelID),
                    default: []
                ].append(Interval(from: alias.effectiveFrom, to: alias.effectiveTo))
                aliases.append(alias)
            }

            var rates: [ValidatedCatalogRate] = []
            for rate in model.rates {
                try validateInterval(from: rate.effectiveFrom, to: rate.effectiveTo)
                try validateDate(rate.verifiedAt)
                let provenanceURL = try validatedURL(rate.provenanceURL)
                guard Self.allowedHosts(for: model.provider).contains(provenanceURL.host?.lowercased() ?? "") else {
                    throw PricingCatalogValidationError.invalidProvenance(provider: model.provider)
                }

                var prices: [UsageMetric: Decimal] = [:]
                for (rawMetric, price) in rate.prices {
                    guard let metric = UsageMetric(rawValue: rawMetric), Self.allowedMetrics.contains(metric) else {
                        throw PricingCatalogValidationError.invalidMetric(rawMetric)
                    }
                    prices[metric] = price.decimal
                    rateIntervals[
                        RateKey(
                            provider: model.provider,
                            canonicalModelID: model.canonicalModelID,
                            metric: metric
                        ),
                        default: []
                    ].append(Interval(from: rate.effectiveFrom, to: rate.effectiveTo))
                }
                for required in [UsageMetric.inputUncached, .output] where prices[required] == nil {
                    throw PricingCatalogValidationError.missingRequiredMetric(required.rawValue)
                }
                rates.append(ValidatedCatalogRate(
                    effectiveFrom: rate.effectiveFrom,
                    effectiveTo: rate.effectiveTo,
                    prices: prices,
                    provenanceURL: provenanceURL,
                    verifiedAt: rate.verifiedAt
                ))
            }

            validatedModels.append(ValidatedCatalogModel(
                provider: model.provider,
                canonicalModelID: model.canonicalModelID,
                aliases: aliases.sorted(by: Self.aliasOrder),
                rates: rates.sorted(by: Self.rateOrder)
            ))
        }

        for key in aliasIntervals.keys.sorted(by: Self.aliasKeyOrder) {
            let intervals = aliasIntervals[key, default: []]
            try validate(intervals: intervals, label: "\(key.provider.rawValue)/\(key.observedModelID)")
        }
        for key in rateIntervals.keys.sorted(by: Self.rateKeyOrder) {
            let intervals = rateIntervals[key, default: []]
            try validate(
                intervals: intervals,
                label: "\(key.provider.rawValue)/\(key.canonicalModelID)/\(key.metric.rawValue)"
            )
        }

        validatedModels.sort(by: Self.modelOrder)
        let canonicalJSON = try canonicalJSON(
            schemaVersion: catalog.schemaVersion,
            catalogID: catalog.catalogID,
            generatedAt: catalog.generatedAt,
            origin: catalog.origin,
            models: validatedModels
        )
        return ValidatedPricingCatalog(
            schemaVersion: catalog.schemaVersion,
            catalogID: catalog.catalogID,
            generatedAt: catalog.generatedAt,
            origin: catalog.origin,
            models: validatedModels,
            canonicalJSON: canonicalJSON
        )
    }

    private func validateIdentifier(_ value: String, label: String) throws {
        guard (1...256).contains(value.utf8.count),
              value.utf8.allSatisfy(Self.allowedIdentifierBytes.contains) else {
            throw PricingCatalogValidationError.invalidIdentifier(label)
        }
    }

    private func validateOrigin(_ origin: CatalogOrigin) throws {
        let components = try validatedURLComponents(origin.url)
        let host = components.host?.lowercased() ?? ""
        switch origin.kind {
        case .tokenboardRepository:
            guard host == "raw.githubusercontent.com" else {
                throw PricingCatalogValidationError.invalidOrigin
            }
            try validateRepositoryPath(components.percentEncodedPath)
        case .officialResearch:
            guard Self.allOfficialHosts.contains(host) else {
                throw PricingCatalogValidationError.invalidOrigin
            }
        }
    }

    private func validatedURL(_ value: String) throws -> URL {
        let components = try validatedURLComponents(value)
        guard let url = components.url else {
            throw PricingCatalogValidationError.invalidURL(value)
        }
        return url
    }

    private func validatedURLComponents(_ value: String) throws -> URLComponents {
        guard let components = URLComponents(string: value),
              components.scheme?.lowercased() == "https",
              components.host != nil,
              components.user == nil,
              components.password == nil,
              components.port == nil,
              components.url != nil else {
            throw PricingCatalogValidationError.invalidURL(value)
        }
        return components
    }

    private func validateRepositoryPath(_ percentEncodedPath: String) throws {
        let rawComponents = percentEncodedPath.split(separator: "/", omittingEmptySubsequences: false)
        guard rawComponents.first == "", rawComponents.count >= 4 else {
            throw PricingCatalogValidationError.invalidOrigin
        }
        var components: [String] = []
        for rawComponent in rawComponents.dropFirst() {
            let component = String(rawComponent)
            guard !component.isEmpty,
                  !component.contains("%"),
                  component != ".",
                  component != "..",
                  !component.contains("\\"),
                  component.unicodeScalars.allSatisfy({ $0.value >= 0x21 && $0.value <= 0x7E }) else {
                throw PricingCatalogValidationError.invalidOrigin
            }
            components.append(component)
        }
        guard components.count >= 3,
              components[0] == "Typiqally",
              components[1] == "tokenboard" else {
            throw PricingCatalogValidationError.invalidOrigin
        }
    }

    private func validateInterval(from: String, to: String?) throws {
        try validateDate(from)
        if let to {
            try validateDate(to)
            guard to > from else {
                throw PricingCatalogValidationError.invalidInterval("\(from)...\(to)")
            }
        }
    }

    private func validateDate(_ value: String) throws {
        guard Self.datePattern.firstMatch(
            in: value,
            range: NSRange(value.startIndex..<value.endIndex, in: value)
        )?.range == NSRange(value.startIndex..<value.endIndex, in: value) else {
            throw PricingCatalogValidationError.invalidDate(value)
        }
        let parts = value.split(separator: "-")
        guard parts.count == 3,
              let year = Int(parts[0]),
              let month = Int(parts[1]),
              let day = Int(parts[2]),
              let date = Self.gregorianCalendar.date(
                from: DateComponents(calendar: Self.gregorianCalendar, year: year, month: month, day: day)
              ) else {
            throw PricingCatalogValidationError.invalidDate(value)
        }
        let components = Self.gregorianCalendar.dateComponents([.year, .month, .day], from: date)
        guard components.year == year, components.month == month, components.day == day else {
            throw PricingCatalogValidationError.invalidDate(value)
        }
    }

    private func validate(intervals: [Interval], label: String) throws {
        let sorted = intervals.sorted { $0.from < $1.from }
        for index in sorted.indices {
            if index > sorted.startIndex {
                let previous = sorted[sorted.index(before: index)]
                let current = sorted[index]
                guard previous.from != current.from else {
                    throw PricingCatalogValidationError.duplicateEffectiveStart(label)
                }
                if let previousEnd = previous.to, previousEnd > current.from {
                    throw PricingCatalogValidationError.overlappingInterval(label)
                }
            }
        }
    }

    private func canonicalJSON(
        schemaVersion: Int,
        catalogID: String,
        generatedAt: String,
        origin: CatalogOrigin,
        models: [ValidatedCatalogModel]
    ) throws -> Data {
        let encodedModels = models.map { model in
            CatalogModel(
                provider: model.provider,
                canonicalModelID: model.canonicalModelID,
                aliases: model.aliases,
                rates: model.rates.map { rate in
                    CatalogRate(
                        effectiveFrom: rate.effectiveFrom,
                        effectiveTo: rate.effectiveTo,
                        prices: Dictionary(uniqueKeysWithValues: rate.prices.map {
                            ($0.key.rawValue, DecimalString(decimal: $0.value))
                        }),
                        provenanceURL: rate.provenanceURL.absoluteString,
                        verifiedAt: rate.verifiedAt
                    )
                }
            )
        }
        let normalized = PricingCatalog(
            schemaVersion: schemaVersion,
            catalogID: catalogID,
            generatedAt: generatedAt,
            origin: origin,
            models: encodedModels
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        do {
            return try encoder.encode(normalized)
        } catch {
            throw PricingCatalogValidationError.canonicalEncodingFailed
        }
    }

    private static func isISO8601Timestamp(_ value: String) -> Bool {
        guard timestampPattern.firstMatch(
            in: value,
            range: NSRange(value.startIndex..<value.endIndex, in: value)
        )?.range == NSRange(value.startIndex..<value.endIndex, in: value) else {
            return false
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        if formatter.date(from: value) != nil {
            return true
        }
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value) != nil
    }

    private static func allowedHosts(for provider: Provider) -> Set<String> {
        switch provider {
        case .claudeCode: anthropicHosts
        case .codex: openAIHosts
        }
    }

    private static func modelOrder(_ lhs: ValidatedCatalogModel, _ rhs: ValidatedCatalogModel) -> Bool {
        (lhs.provider.rawValue, lhs.canonicalModelID) < (rhs.provider.rawValue, rhs.canonicalModelID)
    }

    private static func aliasOrder(_ lhs: CatalogAlias, _ rhs: CatalogAlias) -> Bool {
        (lhs.observedModelID, lhs.effectiveFrom, lhs.effectiveTo ?? "")
            < (rhs.observedModelID, rhs.effectiveFrom, rhs.effectiveTo ?? "")
    }

    private static func rateOrder(_ lhs: ValidatedCatalogRate, _ rhs: ValidatedCatalogRate) -> Bool {
        (lhs.effectiveFrom, lhs.effectiveTo ?? "", lhs.provenanceURL.absoluteString, lhs.verifiedAt)
            < (rhs.effectiveFrom, rhs.effectiveTo ?? "", rhs.provenanceURL.absoluteString, rhs.verifiedAt)
    }

    private static func aliasKeyOrder(_ lhs: AliasKey, _ rhs: AliasKey) -> Bool {
        (lhs.provider.rawValue, lhs.observedModelID) < (rhs.provider.rawValue, rhs.observedModelID)
    }

    private static func rateKeyOrder(_ lhs: RateKey, _ rhs: RateKey) -> Bool {
        (lhs.provider.rawValue, lhs.canonicalModelID, lhs.metric.rawValue)
            < (rhs.provider.rawValue, rhs.canonicalModelID, rhs.metric.rawValue)
    }

    private static let allowedMetrics: Set<UsageMetric> = [
        .inputUncached,
        .inputCacheRead,
        .inputCacheWrite,
        .inputCacheWrite5m,
        .inputCacheWrite1h,
        .output
    ]
    private static let anthropicHosts: Set<String> = [
        "anthropic.com", "www.anthropic.com", "platform.claude.com",
        "docs.anthropic.com", "www-cdn.anthropic.com"
    ]
    private static let openAIHosts: Set<String> = [
        "openai.com", "www.openai.com", "platform.openai.com", "help.openai.com"
    ]
    private static let allOfficialHosts = anthropicHosts.union(openAIHosts)
    private static let allowedIdentifierBytes = Set(
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._:-".utf8
    )
    private static let datePattern = try! NSRegularExpression(pattern: #"^[0-9]{4}-[0-9]{2}-[0-9]{2}$"#)
    private static let timestampPattern = try! NSRegularExpression(
        pattern: #"^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]+)?(Z|[+-][0-9]{2}:[0-9]{2})$"#
    )
    private static let gregorianCalendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }()
}

private struct ModelKey: Hashable {
    let provider: Provider
    let canonicalModelID: String
}

private struct AliasKey: Hashable {
    let provider: Provider
    let observedModelID: String
}

private struct RateKey: Hashable {
    let provider: Provider
    let canonicalModelID: String
    let metric: UsageMetric
}

private struct Interval {
    let from: String
    let to: String?
}

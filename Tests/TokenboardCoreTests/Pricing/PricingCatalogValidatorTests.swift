import Foundation
import XCTest
@testable import TokenboardCore

final class PricingCatalogValidatorTests: XCTestCase {
    private let valid = #"""
    {
      "schemaVersion": 1,
      "catalogID": "test-2026-08-05",
      "generatedAt": "2026-08-05T12:00:00Z",
      "origin": {"kind":"official_research","url":"https://openai.com/api/pricing/"},
      "models": [{
        "provider": "codex",
        "canonicalModelID": "gpt-test",
        "aliases": [{"observedModelID":"gpt-test","effectiveFrom":"2026-01-01","effectiveTo":null}],
        "rates": [{
          "effectiveFrom":"2026-01-01","effectiveTo":null,
          "prices":{"input_uncached":"5.00","input_cache_read":"0.50","output":"30.00"},
          "provenanceURL":"https://openai.com/api/pricing/","verifiedAt":"2026-08-05"
        }]
      }]
    }
    """#

    private var validV2: String {
        valid
            .replacingOccurrences(of: #""schemaVersion": 1"#, with: #""schemaVersion": 2"#)
            .replacingOccurrences(
                of: #""models": ["#,
                with: #"""
      "exchangeRates": {
        "baseCurrency": "USD",
        "effectiveDate": "2026-08-07",
        "verifiedAt": "2026-08-07",
        "provenanceURL": "https://www.ecb.europa.eu/stats/eurofxref/eurofxref-daily.xml",
        "rates": {
          "USD": "1",
          "EUR": "0.866926745",
          "JPY": "158.33550065",
          "GBP": "0.743519723",
          "CNY": "6.747637625"
        }
      },
      "models": [
      """#
            )
    }

    func testValidCatalogNormalizesDecimalRatesAndCanonicalJSON() throws {
        let decoded = try load(valid)
        let catalog = try PricingCatalogValidator().validate(decoded)

        XCTAssertEqual(catalog.catalogID, "test-2026-08-05")
        XCTAssertEqual(catalog.models[0].rates[0].prices[.inputUncached], Decimal(string: "5.00"))
        XCTAssertEqual(catalog.canonicalJSON, try PricingCatalogValidator().validate(decoded).canonicalJSON)
        XCTAssertTrue(String(decoding: catalog.canonicalJSON, as: UTF8.self).contains(#""input_uncached":"5""#))
        let reloaded = try PricingCatalogLoader().load(catalog.canonicalJSON)
        let revalidated = try PricingCatalogValidator().validate(reloaded)
        XCTAssertEqual(revalidated.canonicalJSON, catalog.canonicalJSON)
    }

    func testSchemaV1RemainsUSDOnly() throws {
        let catalog = try validate(valid)

        XCTAssertEqual(catalog.schemaVersion, 1)
        XCTAssertNil(catalog.exchangeRates)
    }

    func testSchemaV2RequiresOneCompleteUSDExchangeSnapshot() throws {
        let catalog = try validate(validV2)
        let exchangeRates = try XCTUnwrap(catalog.exchangeRates)

        XCTAssertEqual(exchangeRates.baseCurrency, .usd)
        XCTAssertEqual(exchangeRates.effectiveDate, "2026-08-07")
        XCTAssertEqual(exchangeRates.verifiedAt, "2026-08-07")
        XCTAssertEqual(
            exchangeRates.provenanceURL.absoluteString,
            "https://www.ecb.europa.eu/stats/eurofxref/eurofxref-daily.xml"
        )
        XCTAssertEqual(exchangeRates.rates[.usd], Decimal(string: "1"))
        XCTAssertEqual(exchangeRates.rates[.eur], Decimal(string: "0.866926745"))
        XCTAssertEqual(exchangeRates.rates[.jpy], Decimal(string: "158.33550065"))
        XCTAssertEqual(exchangeRates.rates[.gbp], Decimal(string: "0.743519723"))
        XCTAssertEqual(exchangeRates.rates[.cny], Decimal(string: "6.747637625"))
        XCTAssertEqual(
            try validate(String(decoding: catalog.canonicalJSON, as: UTF8.self)).canonicalJSON,
            catalog.canonicalJSON
        )
    }

    func testWebResearchCatalogAcceptsReputableHTTPSProvenance() throws {
        let researched = validV2
            .replacingOccurrences(
                of: #""kind":"official_research","url":"https://openai.com/api/pricing/""#,
                with: #""kind":"web_research","url":"https://llmprices.example/research""#
            )
            .replacingOccurrences(
                of: "https://openai.com/api/pricing/",
                with: "https://archive.example/openai-pricing"
            )
            .replacingOccurrences(
                of: "https://www.ecb.europa.eu/stats/eurofxref/eurofxref-daily.xml",
                with: "https://rates.example/usd"
            )

        let catalog = try validate(researched)

        XCTAssertEqual(catalog.origin.kind, .webResearch)
        XCTAssertEqual(
            catalog.models[0].rates[0].provenanceURL.host,
            "archive.example"
        )
        XCTAssertEqual(catalog.exchangeRates?.provenanceURL.host, "rates.example")
    }

    func testSchemaKeysRequireFXOnlyForVersion2() {
        let v1WithFX = validV2.replacingOccurrences(of: #""schemaVersion": 2"#, with: #""schemaVersion": 1"#)
        assertLoadingError(.invalidStructure("catalog has missing or unknown keys")) {
            _ = try load(v1WithFX)
        }

        let v2WithoutFX = valid.replacingOccurrences(of: #""schemaVersion": 1"#, with: #""schemaVersion": 2"#)
        assertLoadingError(.invalidStructure("catalog has missing or unknown keys")) {
            _ = try load(v2WithoutFX)
        }
    }

    func testRejectsInvalidExchangeRateSnapshotSemantics() {
        let cases: [(String, PricingCatalogValidationError)] = [
            (
                validV2.replacingOccurrences(of: #""baseCurrency": "USD""#, with: #""baseCurrency": "EUR""#),
                .invalidExchangeRateSnapshot("base currency must be USD")
            ),
            (
                validV2.replacingOccurrences(of: #""USD": "1""#, with: #""USD": "0.9""#),
                .invalidExchangeRateSnapshot("USD rate must equal 1")
            ),
            (
                validV2.replacingOccurrences(of: #""EUR": "0.866926745","#, with: ""),
                .invalidExchangeRateSnapshot("rates must contain exactly USD, EUR, JPY, GBP, CNY")
            ),
            (
                validV2.replacingOccurrences(of: #""EUR": "0.866926745""#, with: #""EUR": "0""#),
                .invalidExchangeRateSnapshot("EUR rate must be greater than zero")
            ),
            (
                validV2.replacingOccurrences(of: #""effectiveDate": "2026-08-07""#, with: #""effectiveDate": "2026-02-30""#),
                .invalidDate("2026-02-30")
            )
        ]

        for (document, expected) in cases {
            assertValidationError(expected) { _ = try validate(document) }
        }
    }

    func testRejectsUnknownExchangeRateKeysAndUnsupportedSchema() {
        let unknownFXKey = validV2.replacingOccurrences(
            of: #""rates": {"#,
            with: #""unexpected": true, "rates": {"#,
            maxReplacements: 1
        )
        assertLoadingError(.invalidStructure("exchangeRates has missing or unknown keys")) {
            _ = try load(unknownFXKey)
        }

        assertValidationError(.unsupportedSchemaVersion(3)) {
            _ = try validate(validV2.replacingOccurrences(of: #""schemaVersion": 2"#, with: #""schemaVersion": 3"#))
        }
    }

    func testRejectsExactOpaqueUnknownIdentifierAsAnObservedAlias() {
        let opaqueIdentifier = "unknown-" + String(repeating: "a", count: 64)
        let catalog = valid.replacingOccurrences(
            of: #""observedModelID":"gpt-test""#,
            with: #""observedModelID":"\#(opaqueIdentifier)""#
        )

        assertValidationError(.opaqueObservedModelID(opaqueIdentifier)) {
            _ = try validate(catalog)
        }
    }

    func testOpaqueUnknownPolicyRequiresExactLowercaseSHA256Form() throws {
        let lowercase = "unknown-" + String(repeating: "a", count: 64)
        let uppercase = "unknown-" + String(repeating: "A", count: 64)

        XCTAssertTrue(ModelIdentifierPolicy.isOpaqueUnknown(lowercase))
        XCTAssertFalse(ModelIdentifierPolicy.isOpaqueUnknown("unknown-hash"))
        XCTAssertFalse(ModelIdentifierPolicy.isOpaqueUnknown(uppercase))
        XCTAssertFalse(ModelIdentifierPolicy.isOpaqueUnknown(lowercase + "a"))
    }

    func testDocumentByteBoundaryUsesValidCatalog() throws {
        var exact = Data(valid.utf8)
        exact.append(Data(repeating: 0x20, count: 1_048_576 - exact.count))
        XCTAssertEqual(exact.count, 1_048_576)
        XCTAssertNoThrow(try PricingCatalogLoader().load(exact))

        var oversized = exact
        oversized.append(0x20)
        assertLoadingError(.documentTooLarge) {
            _ = try PricingCatalogLoader().load(oversized)
        }
    }

    func testContainerDepthBoundaryUsesStructurallyValidJSON() {
        let atLimit = Data(
            (String(repeating: "[", count: 16) + "null" + String(repeating: "]", count: 16)).utf8
        )
        assertLoadingError(.invalidStructure("catalog must be an object")) {
            _ = try PricingCatalogLoader().load(atLimit)
        }

        let overLimit = Data(
            (String(repeating: "[", count: 17) + "null" + String(repeating: "]", count: 17)).utf8
        )
        assertLoadingError(.documentTooDeep) {
            _ = try PricingCatalogLoader().load(overLimit)
        }
    }

    func testRejectsDuplicateTopLevelMemberBeforeMaterialization() {
        let duplicate = valid.replacingOccurrences(
            of: #""catalogID": "test-2026-08-05""#,
            with: #""catalogID": "test-2026-08-05", "catalogID": "other""#
        )
        assertLoadingError(.duplicateObjectMember("catalogID")) { _ = try load(duplicate) }
    }

    func testRejectsDuplicateNestedAndPricesMembersBeforeMaterialization() {
        let nested = valid.replacingOccurrences(
            of: #""observedModelID":"gpt-test""#,
            with: #""observedModelID":"gpt-test","observedModelID":"gpt-other""#
        )
        assertLoadingError(.duplicateObjectMember("observedModelID")) { _ = try load(nested) }

        let prices = valid.replacingOccurrences(
            of: #""input_uncached":"5.00""#,
            with: #""input_uncached":"5.00","input_uncached":"7.00""#
        )
        assertLoadingError(.duplicateObjectMember("input_uncached")) { _ = try load(prices) }
    }

    func testRejectsEscapedEquivalentDuplicateMemberAndAllowsSingleEscapedKey() {
        let duplicate = valid.replacingOccurrences(
            of: #""catalogID": "test-2026-08-05""#,
            with: #""catalogID": "test-2026-08-05", "catalog\u0049D": "other""#
        )
        assertLoadingError(.duplicateObjectMember("catalogID")) { _ = try load(duplicate) }

        let escapedOnly = valid.replacingOccurrences(
            of: #""catalogID""#,
            with: #""catalog\u0049D""#,
            maxReplacements: 1
        )
        XCTAssertNoThrow(try load(escapedOnly))
    }

    func testMalformedEscapeAndStructureAreInvalidJSON() {
        let malformed = valid.replacingOccurrences(
            of: #""catalogID""#,
            with: #""catalog\qID""#,
            maxReplacements: 1
        )
        assertLoadingError(.invalidJSON) { _ = try load(malformed) }

        let missingColon = valid.replacingOccurrences(
            of: #""schemaVersion": 1"#,
            with: #""schemaVersion" 1"#
        )
        assertLoadingError(.invalidJSON) { _ = try load(missingColon) }
    }

    func testLoaderRejectsUnknownKeysNumbersAndTrailingJSONForSpecificReasons() {
        let unknown = valid.replacingOccurrences(of: #""models":"#, with: #""extra":true,"models":"#)
        assertLoadingError(.invalidStructure("catalog has missing or unknown keys")) { _ = try load(unknown) }
        XCTAssertThrowsError(try load(valid.replacingOccurrences(of: #""5.00""#, with: "5.00")))
        assertLoadingError(.invalidJSON) { _ = try load(valid + " true") }
    }

    func testDecimalStringRejectsNoncanonicalAndOutOfRangeValues() throws {
        for invalid in ["-1", "+1", "01", ".5", "1.", "1e2", "0.1234567890", "100000.000000001"] {
            let changed = valid.replacingOccurrences(of: "5.00", with: invalid)
            XCTAssertThrowsError(try load(changed), "accepted \(invalid)")
        }
        XCTAssertNoThrow(try load(valid.replacingOccurrences(of: "5.00", with: "100000")))
    }

    func testRejectsInvalidDatesRangesMetricsAndRequiredPrices() {
        assertValidationError(.invalidGeneratedAt) {
            _ = try validate(valid.replacingOccurrences(of: "2026-08-05T12:00:00Z", with: "2026-08-05"))
        }
        assertValidationError(.invalidDate("2026-02-30")) {
            _ = try validate(valid.replacingOccurrences(of: "2026-01-01", with: "2026-02-30"))
        }
        assertValidationError(.invalidInterval("2026-01-01...2026-01-01")) {
            _ = try validate(valid.replacingOccurrences(
                of: #""effectiveTo":null"#,
                with: #""effectiveTo":"2026-01-01""#,
                maxReplacements: 1
            ))
        }
        assertValidationError(.invalidMetric("input_unclassified")) {
            _ = try validate(valid.replacingOccurrences(
                of: #""input_cache_read":"0.50","#,
                with: #""input_unclassified":"0.50","#
            ))
        }
        assertValidationError(.missingRequiredMetric("input_uncached")) {
            _ = try validate(valid.replacingOccurrences(of: #""input_uncached":"5.00","#, with: ""))
        }
    }

    func testResearchProvenanceRequiresStructurallySafeHTTPSURLs() throws {
        let decoded = try load(valid)
        let invalidOrigin = PricingCatalog(
            schemaVersion: decoded.schemaVersion,
            catalogID: decoded.catalogID,
            generatedAt: decoded.generatedAt,
            origin: CatalogOrigin(kind: .webResearch, url: "http://prices.example/catalog"),
            models: decoded.models
        )
        assertValidationError(.invalidURL("http://prices.example/catalog")) {
            _ = try PricingCatalogValidator().validate(invalidOrigin)
        }

        let originalModel = decoded.models[0]
        let originalRate = originalModel.rates[0]
        let invalidProvenance = PricingCatalog(
            schemaVersion: decoded.schemaVersion,
            catalogID: decoded.catalogID,
            generatedAt: decoded.generatedAt,
            origin: decoded.origin,
            models: [CatalogModel(
                provider: originalModel.provider,
                canonicalModelID: originalModel.canonicalModelID,
                aliases: originalModel.aliases,
                rates: [CatalogRate(
                    effectiveFrom: originalRate.effectiveFrom,
                    effectiveTo: originalRate.effectiveTo,
                    prices: originalRate.prices,
                    provenanceURL: "https://user:secret@prices.example/rate",
                    verifiedAt: originalRate.verifiedAt
                )]
            )]
        )
        assertValidationError(.invalidURL("https://user:secret@prices.example/rate")) {
            _ = try PricingCatalogValidator().validate(invalidProvenance)
        }
    }

    func testRepositoryOriginRequiresRawASCIISafePathComponents() throws {
        XCTAssertNoThrow(try validateRepositoryOrigin(
            "https://raw.githubusercontent.com/Typiqally/tokenboard/main/Pricing/catalog-v1.json"
        ))
        for invalid in [
            "https://raw.githubusercontent.com/Typiqally/tokenboard/../private/catalog.json",
            "https://raw.githubusercontent.com/Typiqally/tokenboard/main/./catalog.json",
            "https://raw.githubusercontent.com/Typiqally/tokenboard/%2e%2e/private/catalog.json",
            "https://raw.githubusercontent.com/Typiqally/tokenboard/%2E%2e/private/catalog.json",
            "https://raw.githubusercontent.com/Typiqally/tokenboard/%252e%252e/private/catalog.json",
            "https://raw.githubusercontent.com/Typiqally/tokenboard/%252E%252e/private/catalog.json",
            "https://raw.githubusercontent.com/Typiqally/tokenboard/%25252e%25252E/private/catalog.json",
            "https://raw.githubusercontent.com/Typiqally/tokenboard/%2fprivate/catalog.json",
            "https://raw.githubusercontent.com/Typiqally/tokenboard/%252fprivate/catalog.json",
            "https://raw.githubusercontent.com/Typiqally/tokenboard/%252Fprivate/catalog.json",
            "https://raw.githubusercontent.com/Typiqally/tokenboard/%25252fprivate/catalog.json",
            "https://raw.githubusercontent.com/Typiqally/tokenboard/%5cprivate/catalog.json",
            "https://raw.githubusercontent.com/Typiqally/tokenboard/%255cprivate/catalog.json",
            "https://raw.githubusercontent.com/Typiqally/tokenboard/%255Cprivate/catalog.json",
            "https://raw.githubusercontent.com/Typiqally/tokenboard/%25255Cprivate/catalog.json",
            "https://raw.githubusercontent.com/Typiqally/tokenboard/main\\private/catalog.json",
            "https://raw.githubusercontent.com/Typiqally/tokenboard/%6dain/catalog.json",
            "https://raw.githubusercontent.com/Typiqally/tokenboard/main/%2E/catalog.json",
            "https://raw.githubusercontent.com/Typiqally/tokenboard//main/catalog.json",
            "https://raw.githubusercontent.com/Typiqally/tokenboard-evil/main/catalog.json",
            "https://raw.githubusercontent.com/Typiqally/tokenboard/"
        ] {
            assertValidationError(.invalidOrigin, "accepted \(invalid)") {
                _ = try validateRepositoryOrigin(invalid)
            }
        }
    }

    func testRejectsDuplicateRateStartsWithExactError() throws {
        var decoded = try load(valid)
        decoded.models[0].rates.append(decoded.models[0].rates[0])
        assertValidationError(.duplicateEffectiveStart("codex/gpt-test/input_cache_read")) {
            _ = try PricingCatalogValidator().validate(decoded)
        }
    }

    func testRejectsAliasCollisionsAndExplicitIntervalOverlap() throws {
        var catalog = try load(valid)
        let model = CatalogModel(
            provider: .codex,
            canonicalModelID: "gpt-other",
            aliases: [CatalogAlias(observedModelID: "gpt-test", effectiveFrom: "2026-02-01", effectiveTo: nil)],
            rates: [CatalogRate(
                effectiveFrom: "2026-02-01",
                effectiveTo: nil,
                prices: ["input_uncached": DecimalString(decimal: 6), "output": DecimalString(decimal: 31)],
                provenanceURL: "https://openai.com/api/pricing/",
                verifiedAt: "2026-08-05"
            )]
        )
        catalog.models.append(model)
        XCTAssertNoThrow(try PricingCatalogValidator().validate(catalog), "a later start supersedes an open interval")

        let originalModel = catalog.models[0]
        catalog.models[0] = CatalogModel(
            provider: originalModel.provider,
            canonicalModelID: originalModel.canonicalModelID,
            aliases: [CatalogAlias(
                observedModelID: "gpt-test",
                effectiveFrom: "2026-01-01",
                effectiveTo: "2026-03-01"
            )],
            rates: originalModel.rates
        )
        assertValidationError(.overlappingInterval("codex/gpt-test")) {
            _ = try PricingCatalogValidator().validate(catalog)
        }
    }

    private func load(_ string: String) throws -> PricingCatalog {
        try PricingCatalogLoader().load(Data(string.utf8))
    }

    private func validate(_ string: String) throws -> ValidatedPricingCatalog {
        try PricingCatalogValidator().validate(load(string))
    }

    private func validateRepositoryOrigin(_ url: String) throws -> ValidatedPricingCatalog {
        let decoded = try load(valid)
        return try PricingCatalogValidator().validate(PricingCatalog(
            schemaVersion: decoded.schemaVersion,
            catalogID: decoded.catalogID,
            generatedAt: decoded.generatedAt,
            origin: CatalogOrigin(kind: .tokenboardRepository, url: url),
            models: decoded.models
        ))
    }

    private func assertLoadingError(
        _ expected: PricingCatalogLoadingError,
        _ message: String = "",
        file: StaticString = #filePath,
        line: UInt = #line,
        operation: () throws -> Void
    ) {
        do {
            try operation()
            XCTFail("expected \(expected). \(message)", file: file, line: line)
        } catch let error as PricingCatalogLoadingError {
            XCTAssertEqual(error, expected, file: file, line: line)
        } catch {
            XCTFail("expected \(expected), received \(error). \(message)", file: file, line: line)
        }
    }

    private func assertValidationError(
        _ expected: PricingCatalogValidationError,
        _ message: String = "",
        file: StaticString = #filePath,
        line: UInt = #line,
        operation: () throws -> Void
    ) {
        do {
            try operation()
            XCTFail("expected \(expected). \(message)", file: file, line: line)
        } catch let error as PricingCatalogValidationError {
            XCTAssertEqual(error, expected, file: file, line: line)
        } catch {
            XCTFail("expected \(expected), received \(error). \(message)", file: file, line: line)
        }
    }
}

private extension String {
    func replacingOccurrences(of target: String, with replacement: String, maxReplacements: Int) -> String {
        var result = self
        for _ in 0..<maxReplacements {
            guard let range = result.range(of: target) else { break }
            result.replaceSubrange(range, with: replacement)
        }
        return result
    }
}

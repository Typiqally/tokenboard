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

    func testValidCatalogNormalizesDecimalRatesAndCanonicalJSON() throws {
        let decoded = try load(valid)
        let catalog = try PricingCatalogValidator().validate(decoded)

        XCTAssertEqual(catalog.catalogID, "test-2026-08-05")
        XCTAssertEqual(catalog.models[0].rates[0].prices[.inputUncached], Decimal(string: "5.00"))
        XCTAssertEqual(catalog.canonicalJSON, try PricingCatalogValidator().validate(decoded).canonicalJSON)
        XCTAssertTrue(String(decoding: catalog.canonicalJSON, as: UTF8.self).contains(#""input_uncached":"5""#))
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

    func testProviderProvenanceAndCatalogOriginReachSeparateValidationBranches() throws {
        let decoded = try load(valid)
        let invalidOrigin = PricingCatalog(
            schemaVersion: decoded.schemaVersion,
            catalogID: decoded.catalogID,
            generatedAt: decoded.generatedAt,
            origin: CatalogOrigin(kind: .officialResearch, url: "https://prices.invalid/catalog"),
            models: decoded.models
        )
        assertValidationError(.invalidOrigin) { _ = try PricingCatalogValidator().validate(invalidOrigin) }

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
                    provenanceURL: "https://prices.invalid/rate",
                    verifiedAt: originalRate.verifiedAt
                )]
            )]
        )
        assertValidationError(.invalidProvenance(provider: .codex)) {
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

    func testCatalogDiffReportsSemanticAdditionsAndConflicts() throws {
        let candidate = try validate(valid)
        let empty = PricingSnapshot(catalogIDs: [], rates: [], aliases: [])
        XCTAssertEqual(
            CatalogDiff.compare(candidate: candidate, against: empty),
            CatalogDiff(modelsAdded: ["codex/gpt-test"], aliasesAdded: 1, ratesAdded: 3, conflicts: [])
        )

        let conflict = PricingSnapshot(
            catalogIDs: ["older"],
            rates: [StoredPriceRate(
                provider: .codex,
                canonicalModelID: "gpt-test",
                metric: .inputUncached,
                usdPerMillion: 7,
                effectiveFrom: "2026-01-01",
                effectiveTo: nil,
                provenanceURL: URL(string: "https://openai.com/api/pricing/")!,
                verifiedAt: "2026-08-05"
            )],
            aliases: []
        )
        XCTAssertEqual(CatalogDiff.compare(candidate: candidate, against: conflict).conflicts.count, 1)
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

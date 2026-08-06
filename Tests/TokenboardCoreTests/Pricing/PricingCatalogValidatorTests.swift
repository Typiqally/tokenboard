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
        let decoded = try PricingCatalogLoader().load(Data(valid.utf8))
        let catalog = try PricingCatalogValidator().validate(decoded)

        XCTAssertEqual(catalog.catalogID, "test-2026-08-05")
        XCTAssertEqual(catalog.models[0].rates[0].prices[.inputUncached], Decimal(string: "5.00"))
        XCTAssertEqual(catalog.canonicalJSON, try PricingCatalogValidator().validate(decoded).canonicalJSON)
        XCTAssertTrue(String(decoding: catalog.canonicalJSON, as: UTF8.self).contains(#""input_uncached":"5""#))
    }

    func testRejectsNonOfficialProvenance() throws {
        let changed = valid.replacingOccurrences(
            of: "https://openai.com/api/pricing/",
            with: "https://prices.invalid/rates"
        )
        XCTAssertThrowsError(
            try PricingCatalogValidator().validate(PricingCatalogLoader().load(Data(changed.utf8)))
        )
    }

    func testRejectsDuplicateRateStarts() throws {
        var decoded = try PricingCatalogLoader().load(Data(valid.utf8))
        decoded.models[0].rates.append(decoded.models[0].rates[0])
        XCTAssertThrowsError(try PricingCatalogValidator().validate(decoded))
    }

    func testRejectsOversizedAndOvernestedDocuments() {
        XCTAssertThrowsError(try PricingCatalogLoader().load(Data(repeating: 0x20, count: 1_048_577)))
        let deep = Data(
            String(repeating: "[", count: 17)
                .appending(String(repeating: "]", count: 17))
                .utf8
        )
        XCTAssertThrowsError(try PricingCatalogLoader().load(deep))
    }

    func testLoaderRejectsUnknownKeysNumbersAndTrailingJSON() {
        XCTAssertThrowsError(try load(valid.replacingOccurrences(of: #""models":"#, with: #""extra":true,"models":"#)))
        XCTAssertThrowsError(try load(valid.replacingOccurrences(of: #""5.00""#, with: "5.00")))
        XCTAssertThrowsError(try load(valid + " true"))
    }

    func testDecimalStringRejectsNoncanonicalAndOutOfRangeValues() throws {
        for invalid in ["-1", "+1", "01", ".5", "1.", "1e2", "0.1234567890", "100000.000000001"] {
            let changed = valid.replacingOccurrences(of: "5.00", with: invalid)
            XCTAssertThrowsError(try load(changed), "accepted \(invalid)")
        }
        XCTAssertNoThrow(try load(valid.replacingOccurrences(of: "5.00", with: "100000")))
    }

    func testRejectsInvalidDatesRangesMetricsAndRequiredPrices() {
        XCTAssertThrowsError(try validate(valid.replacingOccurrences(of: "2026-08-05T12:00:00Z", with: "2026-08-05")))
        XCTAssertThrowsError(try validate(valid.replacingOccurrences(of: "2026-01-01", with: "2026-02-30")))
        XCTAssertThrowsError(try validate(valid.replacingOccurrences(of: #""effectiveTo":null"#, with: #""effectiveTo":"2026-01-01""#, maxReplacements: 1)))
        XCTAssertThrowsError(try validate(valid.replacingOccurrences(of: #""input_cache_read":"0.50","#, with: #""input_unclassified":"0.50","#)))
        XCTAssertThrowsError(try validate(valid.replacingOccurrences(of: #""input_uncached":"5.00","#, with: "")))
    }

    func testRejectsProviderHostSuffixTricksAndRepositoryPathTricks() {
        XCTAssertThrowsError(try validate(valid.replacingOccurrences(of: "openai.com", with: "openai.com.attacker.invalid")))
        let repository = valid
            .replacingOccurrences(of: "official_research", with: "tokenboard_repository")
            .replacingOccurrences(of: "https://openai.com/api/pricing/", with: "https://raw.githubusercontent.com/Typiqally/tokenboard-evil/main/pricing.json")
        XCTAssertThrowsError(try validate(repository))
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
        XCTAssertThrowsError(try PricingCatalogValidator().validate(catalog))
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

import Foundation
import XCTest
@testable import TokenboardCore

final class BundledCatalogTests: XCTestCase {
    func testBundledCatalogValidatesAndPricesCurrentModelFamilies() throws {
        let data = try Data(contentsOf: TestRepository.root.appending(path: "Resources/tokenboard-pricing.json"))
        let catalog = try PricingCatalogValidator().validate(PricingCatalogLoader().load(data))

        XCTAssertEqual(catalog.schemaVersion, 2)
        XCTAssertEqual(catalog.catalogID, "tokenboard-2026-08-10-1")
        XCTAssertEqual(
            Set(catalog.models.flatMap(\.aliases).map(\.observedModelID)),
            [
                "claude-fable-5",
                "claude-haiku-4-5",
                "claude-haiku-4-5-20251001",
                "claude-mythos-5",
                "claude-opus-4-8",
                "claude-opus-5",
                "claude-sonnet-5",
                "gpt-5.6",
                "gpt-5.6-luna",
                "gpt-5.6-sol",
                "gpt-5.6-terra"
            ]
        )

        try assertRate(
            in: catalog,
            modelID: "claude-fable-5",
            from: "2026-06-09",
            prices: claudePrices(input: "10", cacheRead: "1", cacheWrite5m: "12.5", cacheWrite1h: "20", output: "50"),
            provenance: anthropicPricing
        )
        try assertRate(
            in: catalog,
            modelID: "claude-mythos-5",
            from: "2026-06-09",
            prices: claudePrices(input: "10", cacheRead: "1", cacheWrite5m: "12.5", cacheWrite1h: "20", output: "50"),
            provenance: anthropicPricing
        )
        try assertRate(
            in: catalog,
            modelID: "claude-opus-4-8",
            from: "2026-05-28",
            prices: claudePrices(input: "5", cacheRead: "0.5", cacheWrite5m: "6.25", cacheWrite1h: "10", output: "25"),
            provenance: anthropicPricing
        )
        try assertRate(
            in: catalog,
            modelID: "claude-opus-5",
            from: "2026-07-24",
            prices: claudePrices(input: "5", cacheRead: "0.5", cacheWrite5m: "6.25", cacheWrite1h: "10", output: "25"),
            provenance: "https://platform.claude.com/docs/en/about-claude/models/whats-new-opus-5"
        )
        try assertRate(
            in: catalog,
            modelID: "claude-sonnet-5",
            from: "2026-06-30",
            to: "2026-08-31",
            prices: claudePrices(input: "2", cacheRead: "0.2", cacheWrite5m: "2.5", cacheWrite1h: "4", output: "10"),
            provenance: anthropicPricing
        )
        try assertRate(
            in: catalog,
            modelID: "claude-sonnet-5",
            from: "2026-09-01",
            prices: claudePrices(input: "3", cacheRead: "0.3", cacheWrite5m: "3.75", cacheWrite1h: "6", output: "15"),
            provenance: anthropicPricing
        )
        try assertRate(
            in: catalog,
            modelID: "claude-haiku-4-5-20251001",
            from: "2025-10-15",
            prices: claudePrices(input: "1", cacheRead: "0.1", cacheWrite5m: "1.25", cacheWrite1h: "2", output: "5"),
            provenance: anthropicPricing
        )
        let haiku = try model(in: catalog, named: "claude-haiku-4-5-20251001")
        XCTAssertEqual(Set(haiku.aliases.map(\.observedModelID)), ["claude-haiku-4-5", "claude-haiku-4-5-20251001"])

        try assertRate(
            in: catalog,
            modelID: "gpt-5.6-sol",
            from: "2026-07-09",
            prices: openAIPrices(input: "5", cacheRead: "0.5", cacheWrite: "6.25", output: "30"),
            provenance: openAIPricing
        )
        let sol = try model(in: catalog, named: "gpt-5.6-sol")
        XCTAssertEqual(Set(sol.aliases.map(\.observedModelID)), ["gpt-5.6", "gpt-5.6-sol"])

        try assertRate(
            in: catalog,
            modelID: "gpt-5.6-terra",
            from: "2026-07-09",
            to: "2026-07-29",
            prices: openAIPrices(input: "2.5", cacheRead: "0.25", cacheWrite: "3.125", output: "15"),
            provenance: openAIChangelog
        )
        try assertRate(
            in: catalog,
            modelID: "gpt-5.6-terra",
            from: "2026-07-30",
            prices: openAIPrices(input: "2", cacheRead: "0.2", cacheWrite: "2.5", output: "12"),
            provenance: openAIPricing
        )
        try assertRate(
            in: catalog,
            modelID: "gpt-5.6-luna",
            from: "2026-07-09",
            to: "2026-07-29",
            prices: openAIPrices(input: "1", cacheRead: "0.1", cacheWrite: "1.25", output: "6"),
            provenance: openAIChangelog
        )
        try assertRate(
            in: catalog,
            modelID: "gpt-5.6-luna",
            from: "2026-07-30",
            prices: openAIPrices(input: "0.2", cacheRead: "0.02", cacheWrite: "0.25", output: "1.2"),
            provenance: openAIPricing
        )

        let exchangeRates = try XCTUnwrap(catalog.exchangeRates)
        XCTAssertEqual(exchangeRates.baseCurrency, .usd)
        XCTAssertEqual(exchangeRates.effectiveDate, "2026-08-07")
        XCTAssertEqual(exchangeRates.verifiedAt, "2026-08-07")
        XCTAssertEqual(
            exchangeRates.provenanceURL.absoluteString,
            "https://www.ecb.europa.eu/stats/eurofxref/eurofxref-daily.xml"
        )
        XCTAssertEqual(exchangeRates.rates[.usd], 1)
        XCTAssertEqual(exchangeRates.rates[.eur], Decimal(string: "0.866926745"))
        XCTAssertEqual(exchangeRates.rates[.jpy], Decimal(string: "158.33550065"))
        XCTAssertEqual(exchangeRates.rates[.gbp], Decimal(string: "0.743519723"))
        XCTAssertEqual(exchangeRates.rates[.cny], Decimal(string: "6.747637625"))
    }

    private func model(
        in catalog: ValidatedPricingCatalog,
        named modelID: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> ValidatedCatalogModel {
        try XCTUnwrap(
            catalog.models.first(where: { $0.canonicalModelID == modelID }),
            "missing \(modelID)",
            file: file,
            line: line
        )
    }

    private func assertRate(
        in catalog: ValidatedPricingCatalog,
        modelID: String,
        from effectiveFrom: String,
        to effectiveTo: String? = nil,
        prices: [UsageMetric: Decimal],
        provenance: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let model = try model(in: catalog, named: modelID, file: file, line: line)
        let rate = try XCTUnwrap(
            model.rates.first(where: { $0.effectiveFrom == effectiveFrom }),
            "missing \(modelID) rate beginning \(effectiveFrom)",
            file: file,
            line: line
        )
        XCTAssertEqual(rate.effectiveTo, effectiveTo, file: file, line: line)
        XCTAssertEqual(rate.prices, prices, file: file, line: line)
        XCTAssertEqual(rate.provenanceURL.absoluteString, provenance, file: file, line: line)
        XCTAssertEqual(rate.verifiedAt, "2026-08-10", file: file, line: line)
    }

    private func claudePrices(
        input: String,
        cacheRead: String,
        cacheWrite5m: String,
        cacheWrite1h: String,
        output: String
    ) -> [UsageMetric: Decimal] {
        [
            .inputUncached: Decimal(string: input)!,
            .inputCacheRead: Decimal(string: cacheRead)!,
            .inputCacheWrite5m: Decimal(string: cacheWrite5m)!,
            .inputCacheWrite1h: Decimal(string: cacheWrite1h)!,
            .output: Decimal(string: output)!
        ]
    }

    private func openAIPrices(
        input: String,
        cacheRead: String,
        cacheWrite: String,
        output: String
    ) -> [UsageMetric: Decimal] {
        [
            .inputUncached: Decimal(string: input)!,
            .inputCacheRead: Decimal(string: cacheRead)!,
            .inputCacheWrite: Decimal(string: cacheWrite)!,
            .output: Decimal(string: output)!
        ]
    }

    private var anthropicPricing: String {
        "https://platform.claude.com/docs/en/about-claude/pricing"
    }

    private var openAIPricing: String {
        "https://developers.openai.com/api/docs/pricing"
    }

    private var openAIChangelog: String {
        "https://developers.openai.com/api/docs/changelog"
    }
}

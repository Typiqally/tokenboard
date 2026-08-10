import Foundation
import XCTest
@testable import TokenboardCore

final class BundledCatalogTests: XCTestCase {
    func testBundledCatalogValidatesAndPricesCurrentModelFamilies() throws {
        let data = try Data(contentsOf: TestRepository.root.appending(path: "Resources/tokenboard-pricing.json"))
        let catalog = try PricingCatalogValidator().validate(PricingCatalogLoader().load(data))

        XCTAssertEqual(catalog.schemaVersion, 2)
        XCTAssertEqual(catalog.catalogID, "tokenboard-2026-08-10-2")
        let latestAliases: Set<String> = [
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
        XCTAssertTrue(latestAliases.isSubset(of: Set(catalog.models.flatMap(\.aliases).map(\.observedModelID))))

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
        XCTAssertEqual(exchangeRates.effectiveDate, "2026-08-10")
        XCTAssertEqual(exchangeRates.verifiedAt, "2026-08-10")
        XCTAssertEqual(
            exchangeRates.provenanceURL.absoluteString,
            "https://www.ecb.europa.eu/stats/eurofxref/eurofxref-daily.xml"
        )
        XCTAssertEqual(exchangeRates.rates[.usd], 1)
        XCTAssertEqual(exchangeRates.rates[.eur], Decimal(string: "0.865426222"))
        XCTAssertEqual(exchangeRates.rates[.jpy], Decimal(string: "158.641280831"))
        XCTAssertEqual(exchangeRates.rates[.gbp], Decimal(string: "0.740501947"))
        XCTAssertEqual(exchangeRates.rates[.cny], Decimal(string: "6.744353094"))
    }

    func testBundledCatalogPricesHistoricalGPTAndClaudeFamilies() throws {
        let data = try Data(contentsOf: TestRepository.root.appending(path: "Resources/tokenboard-pricing.json"))
        let catalog = try PricingCatalogValidator().validate(PricingCatalogLoader().load(data))

        let historicalRates: [(String, String, [UsageMetric: Decimal], String)] = [
            ("gpt-5", "2025-08-07", openAIPrices(input: "1.25", cacheRead: "0.125", output: "10"), openAIModel("gpt-5")),
            ("gpt-5-mini", "2025-08-07", openAIPrices(input: "0.25", cacheRead: "0.025", output: "2"), openAIModel("gpt-5-mini")),
            ("gpt-5-nano", "2025-08-07", openAIPrices(input: "0.05", cacheRead: "0.005", output: "0.4"), openAIModel("gpt-5-nano")),
            ("gpt-5-pro", "2025-10-06", openAIPrices(input: "15", output: "120"), openAIModel("gpt-5-pro")),
            ("gpt-5-codex", "2025-09-15", openAIPrices(input: "1.25", cacheRead: "0.125", output: "10"), openAIModel("gpt-5-codex")),
            ("gpt-5.1", "2025-11-13", openAIPrices(input: "1.25", cacheRead: "0.125", output: "10"), openAIModel("gpt-5.1")),
            ("gpt-5.1-codex", "2025-11-13", openAIPrices(input: "1.25", cacheRead: "0.125", output: "10"), openAIModel("gpt-5.1-codex")),
            ("gpt-5.1-codex-max", "2025-11-18", openAIPrices(input: "1.25", cacheRead: "0.125", output: "10"), openAIModel("gpt-5.1-codex-max")),
            ("gpt-5.1-codex-mini", "2025-11-13", openAIPrices(input: "0.25", cacheRead: "0.025", output: "2"), openAIModel("gpt-5.1-codex-mini")),
            ("gpt-5.2", "2025-12-11", openAIPrices(input: "1.75", cacheRead: "0.175", output: "14"), openAIModel("gpt-5.2")),
            ("gpt-5.2-pro", "2025-12-11", openAIPrices(input: "21", output: "168"), openAIModel("gpt-5.2-pro")),
            ("gpt-5.2-codex", "2025-12-18", openAIPrices(input: "1.75", cacheRead: "0.175", output: "14"), openAIModel("gpt-5.2-codex")),
            ("gpt-5.3-codex", "2026-02-05", openAIPrices(input: "1.75", cacheRead: "0.175", output: "14"), openAIModel("gpt-5.3-codex")),
            ("gpt-5.4", "2026-03-05", openAIPrices(input: "2.5", cacheRead: "0.25", output: "15"), openAIModel("gpt-5.4")),
            ("gpt-5.4-mini", "2026-03-17", openAIPrices(input: "0.75", cacheRead: "0.075", output: "4.5"), openAIModel("gpt-5.4-mini")),
            ("gpt-5.4-nano", "2026-03-17", openAIPrices(input: "0.2", cacheRead: "0.02", output: "1.25"), openAIModel("gpt-5.4-nano")),
            ("gpt-5.4-pro", "2026-03-05", openAIPrices(input: "30", output: "180"), openAIModel("gpt-5.4-pro")),
            ("gpt-5.5", "2026-04-23", openAIPrices(input: "5", cacheRead: "0.5", output: "30"), openAIModel("gpt-5.5")),
            ("gpt-5.5-pro", "2026-04-23", openAIPrices(input: "30", output: "180"), openAIModel("gpt-5.5-pro")),
            ("claude-3-opus-20240229", "2024-03-04", claudePrices(input: "15", cacheRead: "1.5", cacheWrite5m: "18.75", cacheWrite1h: "30", output: "75"), anthropicHistoricalPricing),
            ("claude-3-sonnet-20240229", "2024-03-04", claudePrices(input: "3", cacheRead: "0.3", cacheWrite5m: "3.75", cacheWrite1h: "6", output: "15"), anthropicClaude3),
            ("claude-3-haiku-20240307", "2024-03-14", claudePrices(input: "0.25", cacheRead: "0.03", cacheWrite5m: "0.3", cacheWrite1h: "0.5", output: "1.25"), anthropicHistoricalPricing),
            ("claude-3-5-sonnet-20240620", "2024-06-20", claudePrices(input: "3", cacheRead: "0.3", cacheWrite5m: "3.75", cacheWrite1h: "6", output: "15"), anthropicSonnet35),
            ("claude-3-5-sonnet-20241022", "2024-10-22", claudePrices(input: "3", cacheRead: "0.3", cacheWrite5m: "3.75", cacheWrite1h: "6", output: "15"), anthropicSonnet35October),
            ("claude-3-5-haiku-20241022", "2024-11-04", claudePrices(input: "0.8", cacheRead: "0.08", cacheWrite5m: "1", cacheWrite1h: "1.6", output: "4"), anthropicPricing),
            ("claude-3-7-sonnet-20250219", "2025-02-24", claudePrices(input: "3", cacheRead: "0.3", cacheWrite5m: "3.75", cacheWrite1h: "6", output: "15"), anthropicHistoricalPricing),
            ("claude-opus-4-20250514", "2025-05-22", claudePrices(input: "15", cacheRead: "1.5", cacheWrite5m: "18.75", cacheWrite1h: "30", output: "75"), anthropicPricing),
            ("claude-sonnet-4-20250514", "2025-05-22", claudePrices(input: "3", cacheRead: "0.3", cacheWrite5m: "3.75", cacheWrite1h: "6", output: "15"), anthropicPricing),
            ("claude-opus-4-1-20250805", "2025-08-05", claudePrices(input: "15", cacheRead: "1.5", cacheWrite5m: "18.75", cacheWrite1h: "30", output: "75"), anthropicPricing),
            ("claude-sonnet-4-5-20250929", "2025-09-29", claudePrices(input: "3", cacheRead: "0.3", cacheWrite5m: "3.75", cacheWrite1h: "6", output: "15"), anthropicPricing),
            ("claude-opus-4-5-20251101", "2025-11-24", claudePrices(input: "5", cacheRead: "0.5", cacheWrite5m: "6.25", cacheWrite1h: "10", output: "25"), anthropicPricing),
            ("claude-opus-4-6", "2026-02-05", claudePrices(input: "5", cacheRead: "0.5", cacheWrite5m: "6.25", cacheWrite1h: "10", output: "25"), anthropicPricing),
            ("claude-sonnet-4-6", "2026-02-17", claudePrices(input: "3", cacheRead: "0.3", cacheWrite5m: "3.75", cacheWrite1h: "6", output: "15"), anthropicPricing),
            ("claude-opus-4-7", "2026-04-16", claudePrices(input: "5", cacheRead: "0.5", cacheWrite5m: "6.25", cacheWrite1h: "10", output: "25"), anthropicPricing)
        ]

        for (modelID, effectiveFrom, prices, provenance) in historicalRates {
            try assertRate(
                in: catalog,
                modelID: modelID,
                from: effectiveFrom,
                prices: prices,
                provenance: provenance
            )
        }

        let expectedAliases: [String: Set<String>] = [
            "gpt-5": ["gpt-5", "gpt-5-2025-08-07"],
            "gpt-5.1": ["gpt-5.1", "gpt-5.1-2025-11-13"],
            "gpt-5.2": ["gpt-5.2", "gpt-5.2-2025-12-11"],
            "gpt-5.4": ["gpt-5.4", "gpt-5.4-2026-03-05"],
            "gpt-5.5": ["gpt-5.5", "gpt-5.5-2026-04-23"],
            "claude-opus-4-5-20251101": ["claude-opus-4-5", "claude-opus-4-5-20251101"],
            "claude-sonnet-4-5-20250929": ["claude-sonnet-4-5", "claude-sonnet-4-5-20250929"]
        ]
        for (canonicalModelID, aliases) in expectedAliases {
            let catalogModel = try model(in: catalog, named: canonicalModelID)
            XCTAssertEqual(Set(catalogModel.aliases.map(\.observedModelID)), aliases, canonicalModelID)
        }
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
        cacheRead: String? = nil,
        cacheWrite: String? = nil,
        output: String
    ) -> [UsageMetric: Decimal] {
        var prices: [UsageMetric: Decimal] = [
            .inputUncached: Decimal(string: input)!,
            .output: Decimal(string: output)!
        ]
        if let cacheRead {
            prices[.inputCacheRead] = Decimal(string: cacheRead)!
        }
        if let cacheWrite {
            prices[.inputCacheWrite] = Decimal(string: cacheWrite)!
        }
        return prices
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

    private func openAIModel(_ modelID: String) -> String {
        "https://developers.openai.com/api/docs/models/\(modelID)"
    }

    private var anthropicHistoricalPricing: String {
        "https://platform.claude.com/docs/en/about-claude/pricing?46f68bc1_page=4&835f38dd_page=2&e45d281a_page=4"
    }

    private var anthropicClaude3: String {
        "https://www.anthropic.com/news/claude-3-family"
    }

    private var anthropicSonnet35: String {
        "https://www.anthropic.com/news/claude-3-5-sonnet"
    }

    private var anthropicSonnet35October: String {
        "https://www.anthropic.com/news/3-5-models-and-computer-use"
    }
}

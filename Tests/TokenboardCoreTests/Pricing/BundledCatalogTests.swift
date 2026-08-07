import Foundation
import XCTest
@testable import TokenboardCore

final class BundledCatalogTests: XCTestCase {
    func testBundledCatalogValidatesAndPricesObservedCurrentModels() throws {
        let data = try Data(contentsOf: TestRepository.root.appending(path: "Resources/tokenboard-pricing.json"))
        let catalog = try PricingCatalogValidator().validate(PricingCatalogLoader().load(data))

        XCTAssertEqual(catalog.schemaVersion, 2)
        XCTAssertEqual(catalog.catalogID, "tokenboard-2026-08-07-2")
        let aliases = catalog.models.flatMap(\.aliases).map(\.observedModelID)
        XCTAssertEqual(Set(aliases), [
            "claude-fable-5",
            "claude-opus-4-8",
            "claude-opus-5",
            "gpt-5.6-sol"
        ])

        guard let fable = catalog.models.first(where: { $0.canonicalModelID == "claude-fable-5" }) else {
            return XCTFail("missing claude-fable-5")
        }
        XCTAssertEqual(fable.rates.single?.effectiveFrom, "2026-06-09")
        XCTAssertEqual(fable.rates.single?.prices[.inputUncached], Decimal(string: "10.00"))
        XCTAssertEqual(fable.rates.single?.prices[.inputCacheRead], Decimal(string: "1.00"))
        XCTAssertEqual(fable.rates.single?.prices[.inputCacheWrite5m], Decimal(string: "12.50"))
        XCTAssertEqual(fable.rates.single?.prices[.inputCacheWrite1h], Decimal(string: "20.00"))
        XCTAssertEqual(fable.rates.single?.prices[.output], Decimal(string: "50.00"))
        XCTAssertEqual(fable.rates.single?.verifiedAt, "2026-08-07")
        XCTAssertEqual(
            fable.rates.single?.provenanceURL.absoluteString,
            "https://platform.claude.com/docs/en/about-claude/pricing"
        )

        guard let opus48 = catalog.models.first(where: { $0.canonicalModelID == "claude-opus-4-8" }) else {
            return XCTFail("missing claude-opus-4-8")
        }
        XCTAssertEqual(opus48.rates.single?.effectiveFrom, "2026-05-28")
        XCTAssertEqual(opus48.rates.single?.prices[.inputUncached], Decimal(string: "5.00"))
        XCTAssertEqual(opus48.rates.single?.prices[.inputCacheRead], Decimal(string: "0.50"))
        XCTAssertEqual(opus48.rates.single?.prices[.inputCacheWrite5m], Decimal(string: "6.25"))
        XCTAssertEqual(opus48.rates.single?.prices[.inputCacheWrite1h], Decimal(string: "10.00"))
        XCTAssertEqual(opus48.rates.single?.prices[.output], Decimal(string: "25.00"))
        XCTAssertEqual(opus48.rates.single?.verifiedAt, "2026-08-07")
        XCTAssertEqual(
            opus48.rates.single?.provenanceURL.absoluteString,
            "https://platform.claude.com/docs/en/about-claude/pricing"
        )

        guard let opus = catalog.models.first(where: { $0.canonicalModelID == "claude-opus-5" }) else {
            return XCTFail("missing claude-opus-5")
        }
        XCTAssertEqual(opus.rates.single?.effectiveFrom, "2026-07-24")
        XCTAssertEqual(opus.rates.single?.prices[.inputUncached], Decimal(string: "5.00"))
        XCTAssertEqual(opus.rates.single?.prices[.inputCacheRead], Decimal(string: "0.50"))
        XCTAssertEqual(opus.rates.single?.prices[.inputCacheWrite5m], Decimal(string: "6.25"))
        XCTAssertEqual(opus.rates.single?.prices[.inputCacheWrite1h], Decimal(string: "10.00"))
        XCTAssertEqual(opus.rates.single?.prices[.output], Decimal(string: "25.00"))
        XCTAssertEqual(opus.rates.single?.provenanceURL.absoluteString, "https://platform.claude.com/docs/en/about-claude/models/whats-new-opus-5")

        guard let sol = catalog.models.first(where: { $0.canonicalModelID == "gpt-5.6-sol" }) else {
            return XCTFail("missing gpt-5.6-sol")
        }
        XCTAssertEqual(sol.rates.single?.effectiveFrom, "2026-07-09")
        XCTAssertEqual(sol.rates.single?.prices[.inputUncached], Decimal(string: "5.00"))
        XCTAssertEqual(sol.rates.single?.prices[.inputCacheRead], Decimal(string: "0.50"))
        XCTAssertEqual(sol.rates.single?.prices[.inputCacheWrite], Decimal(string: "6.25"))
        XCTAssertEqual(sol.rates.single?.prices[.output], Decimal(string: "30.00"))
        XCTAssertEqual(sol.rates.single?.provenanceURL.absoluteString, "https://openai.com/index/gpt-5-6/")

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
}

private extension Array {
    var single: Element? { count == 1 ? self[0] : nil }
}

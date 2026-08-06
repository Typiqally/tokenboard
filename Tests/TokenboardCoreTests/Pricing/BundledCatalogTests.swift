import Foundation
import XCTest
@testable import TokenboardCore

final class BundledCatalogTests: XCTestCase {
    func testBundledCatalogValidatesAndPricesObservedCurrentModels() throws {
        let data = try Data(contentsOf: TestRepository.root.appending(path: "Resources/tokenboard-pricing.json"))
        let catalog = try PricingCatalogValidator().validate(PricingCatalogLoader().load(data))

        XCTAssertEqual(catalog.catalogID, "tokenboard-2026-08-05")
        let aliases = catalog.models.flatMap(\.aliases).map(\.observedModelID)
        XCTAssertEqual(Set(aliases), ["claude-opus-5", "gpt-5.6-sol"])

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
    }
}

private extension Array {
    var single: Element? { count == 1 ? self[0] : nil }
}

import Foundation
import XCTest
@testable import TokenboardCore

final class AppPresentationTests: XCTestCase {
    func testTokenModeUsesCompactStatusAndExactMenuValues() {
        let summary = UsageSummary(
            period: .today,
            tokenTotal: 842_198,
            knownAPIEquivalentUSD: Decimal(string: "7.42")!,
            unpricedTokens: 0
        )

        let view = MenuPresentation(
            summary: summary,
            displayMetric: .tokens
        )

        XCTAssertEqual(view.statusTitle, "842K")
        XCTAssertEqual(view.tokenTitle, "842,198 tokens")
        XCTAssertEqual(view.apiValueTitle, "≈ $7.42 API equivalent")
        XCTAssertNil(view.unpricedTitle)
    }

    func testAPIValueShowsPlusWithoutWarningWhenUsageIsMerelyUnpriced() {
        let summary = UsageSummary(
            period: .thisMonth,
            tokenTotal: 1_000_000,
            knownAPIEquivalentUSD: Decimal(string: "3.00")!,
            unpricedTokens: 84_000
        )

        let view = MenuPresentation(
            summary: summary,
            displayMetric: .apiValue
        )

        XCTAssertEqual(view.statusTitle, "$3.00+")
        XCTAssertEqual(view.unpricedTitle, "84K unpriced")
    }

    func testSelectedCurrencyConvertsEveryAPIEquivalentSurface() {
        let summary = UsageSummary(
            period: .today,
            tokenTotal: 1_000,
            knownAPIEquivalentUSD: Decimal(string: "7.42")!,
            unpricedTokens: 5,
            exchangeRates: exchangeRates(eur: "0.8")
        )

        let view = MenuPresentation(
            summary: summary,
            displayMetric: .apiValue,
            displayCurrency: .eur
        )

        XCTAssertEqual(view.statusTitle, "€5.94+")
        XCTAssertEqual(view.apiValueTitle, "≈ €5.94 API equivalent")
    }

    func testMissingSelectedExchangeRateIsExplicitlyUnavailable() {
        let summary = UsageSummary(
            period: .today,
            tokenTotal: 1_000,
            knownAPIEquivalentUSD: 7,
            unpricedTokens: 0
        )

        let view = MenuPresentation(
            summary: summary,
            displayMetric: .apiValue,
            displayCurrency: .eur
        )

        XCTAssertEqual(view.statusTitle, "—")
        XCTAssertEqual(view.apiValueTitle, "EUR API equivalent unavailable")
    }

    private func exchangeRates(eur: String) -> ExchangeRateSnapshot {
        ExchangeRateSnapshot(
            catalogID: "test",
            effectiveDate: "2026-08-07",
            verifiedAt: "2026-08-07",
            provenanceURL: URL(string: "https://www.ecb.europa.eu/stats/eurofxref/eurofxref-daily.xml")!,
            rates: [.usd: 1, .eur: Decimal(string: eur)!]
        )
    }
}

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
            displayMetric: .tokens,
            hasHealthWarning: false
        )

        XCTAssertEqual(view.statusTitle, "◉ 842K")
        XCTAssertEqual(view.tokenTitle, "842,198 tokens")
        XCTAssertEqual(view.apiValueTitle, "≈ $7.42 API equivalent")
        XCTAssertNil(view.unpricedTitle)
    }

    func testAPIValueShowsPlusAndWarningWhenUsageIsUnpriced() {
        let summary = UsageSummary(
            period: .thisMonth,
            tokenTotal: 1_000_000,
            knownAPIEquivalentUSD: Decimal(string: "3.00")!,
            unpricedTokens: 84_000
        )

        let view = MenuPresentation(
            summary: summary,
            displayMetric: .apiValue,
            hasHealthWarning: true
        )

        XCTAssertEqual(view.statusTitle, "⚠ $3.00+")
        XCTAssertEqual(view.unpricedTitle, "84K unpriced")
    }
}

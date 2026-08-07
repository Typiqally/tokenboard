import Foundation
import XCTest
@testable import TokenboardCore

final class ValueFormatterTests: XCTestCase {
    func testDisplayCurrenciesAreStableAndOrdered() {
        XCTAssertEqual(
            DisplayCurrency.allCases.map(\.rawValue),
            ["USD", "EUR", "JPY", "GBP", "CNY"]
        )
        XCTAssertEqual(DisplayCurrency.jpy.fractionDigits, 0)
        for currency in [DisplayCurrency.usd, .eur, .gbp, .cny] {
            XCTAssertEqual(currency.fractionDigits, 2)
        }
    }

    func testCompactTokensUseThreeSignificantDigits() {
        XCTAssertEqual(ValueFormatter.compactTokens(842_198), "842K")
        XCTAssertEqual(ValueFormatter.compactTokens(1_250), "1.25K")
        XCTAssertEqual(ValueFormatter.compactTokens(999), "999")
    }

    func testUSDUsesAnExplicitDollarPrefix() {
        XCTAssertEqual(ValueFormatter.usd(Decimal(string: "7.42")!), "$7.42")
    }

    func testUSDRoundsToCurrencyPrecision() {
        XCTAssertEqual(
            ValueFormatter.usd(Decimal(string: "1952.7156")!),
            "$1,952.72"
        )
    }

    func testSupportedCurrenciesUseExplicitUnambiguousSymbols() {
        let value = Decimal(string: "1952.7156")!

        XCTAssertEqual(ValueFormatter.currency(value, currency: .usd), "$1,952.72")
        XCTAssertEqual(ValueFormatter.currency(value, currency: .eur), "€1,952.72")
        XCTAssertEqual(ValueFormatter.currency(value, currency: .jpy), "¥1,953")
        XCTAssertEqual(ValueFormatter.currency(value, currency: .gbp), "£1,952.72")
        XCTAssertEqual(ValueFormatter.currency(value, currency: .cny), "CN¥1,952.72")
    }

    func testExactTokensUseStableUSGrouping() {
        XCTAssertEqual(ValueFormatter.exactTokens(842_198), "842,198")
    }

    func testCompactTokensHandlesNegativeValuesAndMillions() {
        XCTAssertEqual(ValueFormatter.compactTokens(-1_250), "-1.25K")
        XCTAssertEqual(ValueFormatter.compactTokens(1_250_000), "1.25M")
    }
}

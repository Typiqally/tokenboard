import Foundation
import XCTest
@testable import TokenboardCore

final class CurrencyConverterTests: XCTestCase {
    func testConvertsCanonicalUSDUsingUnitsPerUSD() {
        XCTAssertEqual(
            CurrencyConverter.convert(
                usd: Decimal(string: "7.42")!,
                to: .eur,
                rates: [.usd: 1, .eur: Decimal(string: "0.8")!]
            ),
            Decimal(string: "5.936")
        )
    }

    func testUSDDoesNotRequireAnExchangeRateSnapshot() {
        XCTAssertEqual(CurrencyConverter.convert(usd: 7, to: .usd, rates: nil), 7)
    }

    func testMissingTargetRateIsUnavailable() {
        XCTAssertNil(CurrencyConverter.convert(usd: 7, to: .gbp, rates: [.usd: 1]))
        XCTAssertNil(CurrencyConverter.convert(usd: 7, to: .eur, rates: nil))
    }
}

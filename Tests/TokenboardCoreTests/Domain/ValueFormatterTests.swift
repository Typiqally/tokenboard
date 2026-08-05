import Foundation
import XCTest
@testable import TokenboardCore

final class ValueFormatterTests: XCTestCase {
    func testCompactTokensUseThreeSignificantDigits() {
        XCTAssertEqual(ValueFormatter.compactTokens(842_198), "842K")
        XCTAssertEqual(ValueFormatter.compactTokens(1_250), "1.25K")
        XCTAssertEqual(ValueFormatter.compactTokens(999), "999")
    }

    func testUSDUsesAnExplicitDollarPrefix() {
        XCTAssertEqual(ValueFormatter.usd(Decimal(string: "7.42")!), "$7.42")
    }

    func testExactTokensUseStableUSGrouping() {
        XCTAssertEqual(ValueFormatter.exactTokens(842_198), "842,198")
    }

    func testCompactTokensHandlesNegativeValuesAndMillions() {
        XCTAssertEqual(ValueFormatter.compactTokens(-1_250), "-1.25K")
        XCTAssertEqual(ValueFormatter.compactTokens(1_250_000), "1.25M")
    }
}

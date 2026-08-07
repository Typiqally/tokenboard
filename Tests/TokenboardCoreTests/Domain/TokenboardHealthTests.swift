import Foundation
import XCTest
@testable import TokenboardCore

final class TokenboardHealthTests: XCTestCase {
    func testReplacingPreservesDiagnosticsAndClampsUsageCounts() {
        let health = makeHealth(skippedRecordCount: 3, unpricedTokens: 4)

        let replaced = health.replacing(skippedRecordCount: -1, unpricedTokens: -2)

        XCTAssertEqual(replaced.skippedRecordCount, 0)
        XCTAssertEqual(replaced.unpricedTokens, 0)
        XCTAssertEqual(replaced.claude, health.claude)
        XCTAssertEqual(replaced.codex, health.codex)
    }

    private func makeHealth(
        claude: SourceHealth = .healthy(fileCount: 2, lastUpdated: .distantPast),
        codex: SourceHealth = .healthy(fileCount: 2, lastUpdated: .distantPast),
        database: TokenboardHealth.DatabaseState = .healthy,
        skippedRecordCount: Int = 0,
        unpricedTokens: Int64 = 0,
        pricing: TokenboardHealth.PricingState = .healthy
    ) -> TokenboardHealth {
        TokenboardHealth(
            claude: claude,
            codex: codex,
            database: database,
            lastSuccessfulScan: .distantPast,
            skippedRecordCount: skippedRecordCount,
            unpricedTokens: unpricedTokens,
            pricing: pricing
        )
    }
}

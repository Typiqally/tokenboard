import Foundation
import XCTest
@testable import TokenboardCore

final class TokenboardHealthTests: XCTestCase {
    func testRoutinePricingAndOptionalGrantStatesStayNeutralInMenuBar() {
        let health = makeHealth(
            claude: .notGranted,
            unpricedTokens: 84_000,
            pricing: .warning(message: "Invalid candidate; active pricing unchanged")
        )

        XCTAssertTrue(health.hasWarning)
        XCTAssertFalse(health.hasDisplayIntegrityWarning)
    }

    func testIncompleteOrUnavailableTotalsRaiseDisplayIntegrityWarning() {
        XCTAssertTrue(makeHealth(
            claude: .warning(message: "Import is paused")
        ).hasDisplayIntegrityWarning)
        XCTAssertTrue(makeHealth(
            database: .recoveryRequired(message: "Recovery required")
        ).hasDisplayIntegrityWarning)
        XCTAssertTrue(makeHealth(
            skippedRecordCount: 1
        ).hasDisplayIntegrityWarning)
    }

    func testHealthyAndIndexingSourcesStayNeutralInMenuBar() {
        XCTAssertFalse(makeHealth(
            claude: .indexing(fileCount: 3)
        ).hasDisplayIntegrityWarning)
        XCTAssertFalse(makeHealth().hasDisplayIntegrityWarning)
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

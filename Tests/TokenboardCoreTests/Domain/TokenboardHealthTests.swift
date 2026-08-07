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
            claude: .warning(issue: .importFailure, message: "Import is paused")
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

    func testDismissibleWarningSignatureIsStableAndContainsNoMessageData() throws {
        let health = makeHealth(
            claude: .warning(
                issue: .truncatedLog,
                message: "private-looking /Users/example/project"
            ),
            codex: .warning(issue: .unknownFormats, message: "different display copy"),
            skippedRecordCount: 7
        )

        let first = try XCTUnwrap(health.dismissibleWarningSignature)
        let second = try XCTUnwrap(health.dismissibleWarningSignature)

        XCTAssertEqual(first, second)
        XCTAssertEqual(first.digest.count, 64)
        XCTAssertTrue(first.digest.allSatisfy { $0.isHexDigit && !$0.isUppercase })
        XCTAssertFalse(first.digest.contains("Users"))
        XCTAssertFalse(first.digest.contains("project"))
    }

    func testCanonicalDigestIsIndependentOfComponentOrdering() {
        let components = [
            "source|codex|truncated_log",
            "source|claude_code|unknown_formats",
            "skipped|7"
        ]

        XCTAssertEqual(
            DismissibleWarningSignature.digest(components: components),
            DismissibleWarningSignature.digest(components: components.reversed())
        )
    }

    func testWarningSignatureChangesWithIssueProviderOrSkippedCount() throws {
        let claudeTruncated = try XCTUnwrap(makeHealth(
            claude: .warning(issue: .truncatedLog, message: "paused")
        ).dismissibleWarningSignature)
        let claudeReplaced = try XCTUnwrap(makeHealth(
            claude: .warning(issue: .replacedLog, message: "paused")
        ).dismissibleWarningSignature)
        let codexTruncated = try XCTUnwrap(makeHealth(
            codex: .warning(issue: .truncatedLog, message: "paused")
        ).dismissibleWarningSignature)
        let skipped = try XCTUnwrap(makeHealth(
            claude: .warning(issue: .truncatedLog, message: "paused"),
            skippedRecordCount: 1
        ).dismissibleWarningSignature)

        XCTAssertEqual(Set([
            claudeTruncated.digest,
            claudeReplaced.digest,
            codexTruncated.digest,
            skipped.digest
        ]).count, 4)
    }

    func testDatabaseAndApplicationFailuresAreNonDismissible() {
        XCTAssertTrue(makeHealth(
            database: .recoveryRequired(message: "recovery")
        ).hasNonDismissibleDisplayIntegrityWarning)
        XCTAssertTrue(makeHealth(
            claude: .warning(issue: .applicationFailure, message: "startup paused")
        ).hasNonDismissibleDisplayIntegrityWarning)
        XCTAssertNil(makeHealth(
            claude: .warning(issue: .applicationFailure, message: "startup paused")
        ).dismissibleWarningSignature)
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

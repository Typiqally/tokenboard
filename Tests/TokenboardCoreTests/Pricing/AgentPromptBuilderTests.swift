import Foundation
import XCTest
@testable import TokenboardCore

final class AgentPromptBuilderTests: XCTestCase {
    private let paths = AgentPricingPaths(
        currentCatalog: URL(
            fileURLWithPath: "/private/example/Pricing/current-tokenboard-pricing.json"
        ),
        temporaryCatalog: URL(
            fileURLWithPath: "/private/example/Pricing/current-tokenboard-pricing.json.tmp"
        )
    )

    func testPromptUsesBroaderWebSourcesAndReplacesTheActiveCatalog() {
        let prompt = AgentPromptBuilder().build(paths: paths)

        XCTAssertTrue(prompt.contains("reputable secondary sources"))
        XCTAssertTrue(prompt.contains("web archives"))
        XCTAssertTrue(prompt.contains("atomically replace the active catalog"))
        XCTAssertTrue(prompt.contains("validating the file locally"))
        XCTAssertTrue(prompt.contains("applies valid changes automatically"))
        XCTAssertFalse(prompt.contains("require me to approve"))
    }

    func testPromptUsesOnlyTheExactTemporaryWritePathAndNeverSQLite() {
        let prompt = AgentPromptBuilder().build(paths: paths)

        XCTAssertTrue(prompt.contains(paths.currentCatalog.path))
        XCTAssertTrue(prompt.contains(paths.temporaryCatalog.path))
        XCTAssertTrue(prompt.contains("Do not open or modify any SQLite file"))
        XCTAssertTrue(prompt.contains("the only permitted write destination"))
        XCTAssertTrue(prompt.contains("If network or filesystem permission is unavailable"))
        XCTAssertFalse(prompt.contains("Pricing/Inbox"))
        XCTAssertFalse(prompt.contains("candidate"))
    }

    func testPromptRequestsOneCompleteSchemaV2LedgerWithoutPrivateUsageData() {
        let prompt = AgentPromptBuilder().build(paths: paths)

        XCTAssertTrue(prompt.contains("schemaVersion 2"))
        XCTAssertTrue(prompt.contains("complete model-pricing ledger"))
        XCTAssertTrue(prompt.contains("USD, EUR, JPY, GBP, and CNY"))
        XCTAssertTrue(prompt.contains("origin kind web_research"))
        XCTAssertTrue(prompt.contains("Do not include transcript content"))
        XCTAssertTrue(prompt.contains("report every source consulted"))
    }
}

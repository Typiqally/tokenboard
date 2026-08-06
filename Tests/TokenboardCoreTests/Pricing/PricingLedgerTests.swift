import Foundation
import XCTest
@testable import TokenboardCore

final class PricingLedgerTests: XCTestCase {
    private let valid = #"""
    {"schemaVersion":1,"catalogID":"catalog-a","generatedAt":"2026-08-05T12:00:00Z","origin":{"kind":"official_research","url":"https://openai.com/api/pricing/"},"models":[{"provider":"codex","canonicalModelID":"gpt-test","aliases":[{"observedModelID":"gpt-test","effectiveFrom":"2026-01-01","effectiveTo":null}],"rates":[{"effectiveFrom":"2026-01-01","effectiveTo":null,"prices":{"input_uncached":"5.00","output":"30.00"},"provenanceURL":"https://openai.com/api/pricing/","verifiedAt":"2026-08-05"}]}]}
    """#

    func testApplyingTwiceIsIdempotentAndSemanticConflictsRollBack() async throws {
        let ledger = try makeLedger()
        try await ledger.migrate()
        let first = try validated(valid)

        try await ledger.applyPricingCatalog(
            first,
            canonicalJSON: first.canonicalJSON,
            origin: "test",
            validationSummary: "valid"
        )
        let afterFirst = try await ledger.pricingSnapshot()
        try await ledger.applyPricingCatalog(
            first,
            canonicalJSON: first.canonicalJSON,
            origin: "ignored-on-idempotent-retry",
            validationSummary: "valid"
        )
        let afterSecond = try await ledger.pricingSnapshot()
        XCTAssertEqual(afterSecond, afterFirst)

        let conflictJSON = valid
            .replacingOccurrences(of: "catalog-a", with: "catalog-b")
            .replacingOccurrences(of: #""5.00""#, with: #""7.00""#)
        let conflicting = try validated(conflictJSON)
        await XCTAssertThrowsErrorAsync {
            try await ledger.applyPricingCatalog(
                conflicting,
                canonicalJSON: conflicting.canonicalJSON,
                origin: "test",
                validationSummary: "valid"
            )
        }
        let afterConflict = try await ledger.pricingSnapshot()
        XCTAssertEqual(afterConflict, afterFirst)
    }

    func testCatalogIDWithDifferentCanonicalContentConflicts() async throws {
        let ledger = try makeLedger()
        try await ledger.migrate()
        let first = try validated(valid)
        try await ledger.applyPricingCatalog(first, canonicalJSON: first.canonicalJSON, origin: "test", validationSummary: "valid")

        let changed = try validated(valid.replacingOccurrences(of: #""5.00""#, with: #""7.00""#))
        await XCTAssertThrowsErrorAsync {
            try await ledger.applyPricingCatalog(changed, canonicalJSON: changed.canonicalJSON, origin: "test", validationSummary: "valid")
        }
        let snapshot = try await ledger.pricingSnapshot()
        XCTAssertEqual(snapshot.catalogIDs, ["catalog-a"])
    }

    func testLaterOpenEndedHistoryAppendsWithoutClosingOlderRows() async throws {
        let ledger = try makeLedger()
        try await ledger.migrate()
        let first = try validated(valid)
        try await ledger.applyPricingCatalog(first, canonicalJSON: first.canonicalJSON, origin: "test", validationSummary: "valid")

        let laterJSON = valid
            .replacingOccurrences(of: "catalog-a", with: "catalog-b")
            .replacingOccurrences(of: "2026-01-01", with: "2026-07-01")
            .replacingOccurrences(of: #""5.00""#, with: #""6.00""#)
        let later = try validated(laterJSON)
        try await ledger.applyPricingCatalog(later, canonicalJSON: later.canonicalJSON, origin: "test", validationSummary: "valid")

        let snapshot = try await ledger.pricingSnapshot()
        XCTAssertEqual(snapshot.catalogIDs, ["catalog-a", "catalog-b"])
        XCTAssertEqual(snapshot.rates.filter { $0.metric == .inputUncached }.map(\.effectiveFrom), ["2026-01-01", "2026-07-01"])
        XCTAssertNil(snapshot.rates.first { $0.effectiveFrom == "2026-01-01" }?.effectiveTo)
    }

    func testApplicationRejectsCanonicalJSONMismatchAndPrivateImportMetadata() async throws {
        let ledger = try makeLedger()
        try await ledger.migrate()
        let catalog = try validated(valid)

        await XCTAssertThrowsErrorAsync {
            try await ledger.applyPricingCatalog(catalog, canonicalJSON: Data("{}".utf8), origin: "test", validationSummary: "valid")
        }
        await XCTAssertThrowsErrorAsync {
            try await ledger.applyPricingCatalog(
                catalog,
                canonicalJSON: catalog.canonicalJSON,
                origin: "/Users/someone/private/catalog.json",
                validationSummary: "valid"
            )
        }
        let snapshot = try await ledger.pricingSnapshot()
        XCTAssertEqual(snapshot, PricingSnapshot(catalogIDs: [], rates: [], aliases: []))
    }

    private func makeLedger() throws -> SQLiteLedger {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return try SQLiteLedger(
            databaseURL: directory.appending(path: "ledger.sqlite"),
            backupDirectory: directory.appending(path: "Backups")
        )
    }

    private func validated(_ json: String) throws -> ValidatedPricingCatalog {
        let decoded = try PricingCatalogLoader().load(Data(json.utf8))
        return try PricingCatalogValidator().validate(decoded)
    }
}

private func XCTAssertThrowsErrorAsync(
    _ expression: () async throws -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        try await expression()
        XCTFail("expected async expression to throw", file: file, line: line)
    } catch {
        return
    }
}

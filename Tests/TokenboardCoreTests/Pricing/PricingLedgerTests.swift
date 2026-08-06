import Foundation
import XCTest
@testable import TokenboardCore

final class PricingLedgerTests: XCTestCase {
    func testApplyingSameCatalogIsIdempotentAndChangedContentForSameIDConflicts() async throws {
        let ledger = try makeLedger()
        try await ledger.migrate()
        let first = try catalog(id: "catalog-a", models: [model()])

        try await apply(first, to: ledger)
        let afterFirst = try await ledger.pricingSnapshot()
        try await apply(
            first,
            to: ledger,
            origin: PricingImportMetadata.bundledRepositoryOrigin
        )
        let afterRetry = try await snapshot(from: ledger)
        XCTAssertEqual(afterRetry, afterFirst)

        let changed = try catalog(id: "catalog-a", models: [model(inputPrice: 7)])
        await assertPricingError(.catalogIDConflict("catalog-a")) {
            try await self.apply(changed, to: ledger)
        }
        let afterConflict = try await snapshot(from: ledger)
        XCTAssertEqual(afterConflict, afterFirst)
    }

    func testFullHistoryImportDeduplicatesExactRowsAndAppendsLaterOpenIntervals() async throws {
        let ledger = try makeLedger()
        try await ledger.migrate()
        let first = try catalog(id: "catalog-a", models: [model()])
        try await apply(first, to: ledger)

        let history = try catalog(id: "catalog-b", models: [CatalogModel(
            provider: .codex,
            canonicalModelID: "gpt-test",
            aliases: [
                alias(from: "2026-01-01", to: nil),
                alias(from: "2026-07-01", to: nil)
            ],
            rates: [
                rate(from: "2026-01-01", to: nil, inputPrice: 5),
                rate(from: "2026-07-01", to: nil, inputPrice: 6)
            ]
        )])
        try await apply(history, to: ledger)

        let snapshot = try await ledger.pricingSnapshot()
        XCTAssertEqual(snapshot.catalogIDs, ["catalog-a", "catalog-b"])
        XCTAssertEqual(snapshot.aliases.map(\.effectiveFrom), ["2026-01-01", "2026-07-01"])
        XCTAssertEqual(
            snapshot.rates.filter { $0.metric == .inputUncached }.map(\.effectiveFrom),
            ["2026-01-01", "2026-07-01"]
        )
        XCTAssertNil(snapshot.rates.first { $0.effectiveFrom == "2026-01-01" }?.effectiveTo)
    }

    func testStoredBoundedRateRejectsCandidateStartInsideInterval() async throws {
        let ledger = try makeLedger()
        try await ledger.migrate()
        let stored = try catalog(id: "catalog-a", models: [model(aliasTo: nil, rateTo: "2026-06-01")])
        try await apply(stored, to: ledger)
        let before = try await ledger.pricingSnapshot()

        let overlapping = try catalog(id: "catalog-b", models: [model(
            aliasFrom: "2026-05-01",
            aliasTo: nil,
            rateFrom: "2026-05-01",
            rateTo: nil,
            inputPrice: 6
        )])
        await assertPricingError(.overlappingInterval("rate codex/gpt-test/input_uncached")) {
            try await self.apply(overlapping, to: ledger)
        }
        let afterRejection = try await snapshot(from: ledger)
        XCTAssertEqual(afterRejection, before)
    }

    func testStoredBoundedAliasRejectsCandidateStartInsideInterval() async throws {
        let ledger = try makeLedger()
        try await ledger.migrate()
        let stored = try catalog(id: "catalog-a", models: [model(aliasTo: "2026-06-01", rateTo: nil)])
        try await apply(stored, to: ledger)
        let before = try await ledger.pricingSnapshot()

        let overlapping = try catalog(id: "catalog-b", models: [model(
            aliasFrom: "2026-05-01",
            aliasTo: nil,
            rateFrom: "2026-05-01",
            rateTo: nil,
            inputPrice: 6
        )])
        await assertPricingError(.overlappingInterval("alias codex/gpt-test")) {
            try await self.apply(overlapping, to: ledger)
        }
        let afterRejection = try await snapshot(from: ledger)
        XCTAssertEqual(afterRejection, before)
    }

    func testStoredExplicitBoundaryAndGapAllowAliasesAndRates() async throws {
        for candidateStart in ["2026-06-01", "2026-07-01"] {
            let ledger = try makeLedger()
            try await ledger.migrate()
            let stored = try catalog(id: "catalog-a", models: [model(
                aliasTo: "2026-06-01",
                rateTo: "2026-06-01"
            )])
            try await apply(stored, to: ledger)
            let candidate = try catalog(id: "catalog-b", models: [model(
                aliasFrom: candidateStart,
                rateFrom: candidateStart,
                inputPrice: 6
            )])

            try await apply(candidate, to: ledger)

            let snapshot = try await ledger.pricingSnapshot()
            XCTAssertEqual(snapshot.catalogIDs, ["catalog-a", "catalog-b"])
            XCTAssertEqual(snapshot.aliases.map(\.effectiveFrom), ["2026-01-01", candidateStart])
            XCTAssertEqual(snapshot.rates.count, 4)
        }
    }

    func testValidNewRowsBeforeLaterOverlapRollBackEntireTransaction() async throws {
        let ledger = try makeLedger()
        try await ledger.migrate()
        let stored = try catalog(id: "catalog-a", models: [model(
            canonicalModelID: "z-conflict",
            observedModelID: "z-conflict",
            aliasTo: "2026-06-01",
            rateTo: "2026-06-01"
        )])
        try await apply(stored, to: ledger)
        let before = try await ledger.pricingSnapshot()

        let candidate = try catalog(id: "catalog-b", models: [
            model(canonicalModelID: "a-new", observedModelID: "a-new", inputPrice: 4),
            model(
                canonicalModelID: "z-conflict",
                observedModelID: "z-conflict",
                aliasFrom: "2026-05-01",
                rateFrom: "2026-05-01",
                inputPrice: 6
            )
        ])
        await assertPricingError(.overlappingInterval("alias codex/z-conflict")) {
            try await self.apply(candidate, to: ledger)
        }

        let afterRejection = try await snapshot(from: ledger)
        XCTAssertEqual(afterRejection, before)
    }

    func testValidNewRowsBeforeLaterSameStartConflictRollBackEntireTransaction() async throws {
        let ledger = try makeLedger()
        try await ledger.migrate()
        let stored = try catalog(id: "catalog-a", models: [model(
            canonicalModelID: "z-conflict",
            observedModelID: "z-conflict"
        )])
        try await apply(stored, to: ledger)
        let before = try await ledger.pricingSnapshot()

        let candidate = try catalog(id: "catalog-b", models: [
            model(canonicalModelID: "a-new", observedModelID: "a-new", inputPrice: 4),
            model(canonicalModelID: "z-conflict", observedModelID: "z-conflict", inputPrice: 7)
        ])
        await assertPricingError(.semanticConflict("rate codex/z-conflict/input_uncached/2026-01-01")) {
            try await self.apply(candidate, to: ledger)
        }

        let afterRejection = try await snapshot(from: ledger)
        XCTAssertEqual(afterRejection, before)
    }

    func testApplicationRejectsCanonicalMismatchAndClosedMetadataValuesWithoutWrites() async throws {
        let ledger = try makeLedger()
        try await ledger.migrate()
        let candidate = try catalog(id: "catalog-a", models: [model()])

        await assertPricingError(.canonicalContentMismatch) {
            try await ledger.applyPricingCatalog(
                candidate,
                canonicalJSON: Data("{}".utf8),
                origin: PricingImportMetadata.agentCandidateOrigin,
                validationSummary: PricingImportMetadata.schemaV1ValidSummary
            )
        }
        for invalidOrigin in ["alice", "alice@example.com", "session-123", "project-zeus"] {
            await assertPricingError(.invalidImportMetadata) {
                try await ledger.applyPricingCatalog(
                    candidate,
                    canonicalJSON: candidate.canonicalJSON,
                    origin: invalidOrigin,
                    validationSummary: PricingImportMetadata.schemaV1ValidSummary
                )
            }
        }
        for invalidSummary in ["alice", "alice@example.com", "session-123", "project-zeus"] {
            await assertPricingError(.invalidImportMetadata) {
                try await ledger.applyPricingCatalog(
                    candidate,
                    canonicalJSON: candidate.canonicalJSON,
                    origin: PricingImportMetadata.agentCandidateOrigin,
                    validationSummary: invalidSummary
                )
            }
        }

        let snapshot = try await snapshot(from: ledger)
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

    private func model(
        canonicalModelID: String = "gpt-test",
        observedModelID: String = "gpt-test",
        aliasFrom: String = "2026-01-01",
        aliasTo: String? = nil,
        rateFrom: String = "2026-01-01",
        rateTo: String? = nil,
        inputPrice: Decimal = 5
    ) -> CatalogModel {
        CatalogModel(
            provider: .codex,
            canonicalModelID: canonicalModelID,
            aliases: [alias(observedModelID: observedModelID, from: aliasFrom, to: aliasTo)],
            rates: [rate(from: rateFrom, to: rateTo, inputPrice: inputPrice)]
        )
    }

    private func alias(
        observedModelID: String = "gpt-test",
        from: String,
        to: String?
    ) -> CatalogAlias {
        CatalogAlias(observedModelID: observedModelID, effectiveFrom: from, effectiveTo: to)
    }

    private func rate(from: String, to: String?, inputPrice: Decimal) -> CatalogRate {
        CatalogRate(
            effectiveFrom: from,
            effectiveTo: to,
            prices: [
                UsageMetric.inputUncached.rawValue: DecimalString(decimal: inputPrice),
                UsageMetric.output.rawValue: DecimalString(decimal: 30)
            ],
            provenanceURL: "https://openai.com/api/pricing/",
            verifiedAt: "2026-08-05"
        )
    }

    private func catalog(id: String, models: [CatalogModel]) throws -> ValidatedPricingCatalog {
        try PricingCatalogValidator().validate(PricingCatalog(
            schemaVersion: 1,
            catalogID: id,
            generatedAt: "2026-08-05T12:00:00Z",
            origin: CatalogOrigin(kind: .officialResearch, url: "https://openai.com/api/pricing/"),
            models: models
        ))
    }

    private func apply(
        _ catalog: ValidatedPricingCatalog,
        to ledger: SQLiteLedger,
        origin: String = PricingImportMetadata.agentCandidateOrigin
    ) async throws {
        try await ledger.applyPricingCatalog(
            catalog,
            canonicalJSON: catalog.canonicalJSON,
            origin: origin,
            validationSummary: PricingImportMetadata.schemaV1ValidSummary
        )
    }

    private func snapshot(from ledger: SQLiteLedger) async throws -> PricingSnapshot {
        try await ledger.pricingSnapshot()
    }

    private func assertPricingError(
        _ expected: PricingLedgerError,
        file: StaticString = #filePath,
        line: UInt = #line,
        operation: () async throws -> Void
    ) async {
        do {
            try await operation()
            XCTFail("expected \(expected)", file: file, line: line)
        } catch let error as PricingLedgerError {
            XCTAssertEqual(error, expected, file: file, line: line)
        } catch {
            XCTFail("expected \(expected), received \(error)", file: file, line: line)
        }
    }
}

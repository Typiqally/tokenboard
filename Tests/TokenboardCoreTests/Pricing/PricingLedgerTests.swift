import Foundation
import XCTest
@testable import TokenboardCore

final class PricingLedgerTests: XCTestCase {
    func testSchemaV2PersistsCompleteExchangeSnapshotAndRetainsHistory() async throws {
        let ledger = try makeLedger()
        try await ledger.migrate()
        let first = try catalogV2(id: "catalog-fx-a", eur: "0.86")
        let second = try catalogV2(id: "catalog-fx-b", eur: "0.87")

        try await apply(first, to: ledger)
        try await apply(second, to: ledger)

        let snapshot = try await ledger.pricingSnapshot()
        XCTAssertEqual(snapshot.exchangeRateSnapshots.count, 2)
        XCTAssertEqual(snapshot.exchangeRateSnapshots.map(\.catalogID), ["catalog-fx-a", "catalog-fx-b"])
        XCTAssertEqual(snapshot.exchangeRateSnapshots[0].rates[.eur], Decimal(string: "0.86"))
        XCTAssertEqual(snapshot.latestExchangeRates?.rates[.eur], Decimal(string: "0.87"))
        XCTAssertEqual(snapshot.latestExchangeRates?.rates[.usd], Decimal(string: "1"))
    }

    func testSchemaV1AppliesWithoutCreatingExchangeSnapshot() async throws {
        let ledger = try makeLedger()
        try await ledger.migrate()

        try await apply(try catalog(id: "catalog-v1", models: [model()]), to: ledger)

        let snapshot = try await ledger.pricingSnapshot()
        XCTAssertTrue(snapshot.exchangeRateSnapshots.isEmpty)
        XCTAssertNil(snapshot.latestExchangeRates)
    }

    func testExchangeRateInsertFailureRollsBackModelAndFXRowsTogether() async throws {
        let setup = try makeLedgerWithDatabase()
        try await setup.ledger.migrate()
        let before = try await setup.ledger.pricingSnapshot()
        let database = try SQLiteConnection(url: setup.databaseURL)
        try database.execute("""
        CREATE TRIGGER reject_jpy_fx
        BEFORE INSERT ON fx_rates
        FOR EACH ROW WHEN NEW.currency_code = 'JPY'
        BEGIN
          SELECT RAISE(ABORT, 'injected FX failure');
        END;
        """)

        await assertSQLiteConstraint(containing: "injected FX failure") {
            try await self.apply(try self.catalogV2(id: "catalog-fx-failure"), to: setup.ledger)
        }

        XCTAssertEqual(try await setup.ledger.pricingSnapshot(), before)
        XCTAssertEqual(
            try database.queryStrings("SELECT catalog_id FROM catalog_imports ORDER BY catalog_id;"),
            []
        )
        XCTAssertEqual(try database.queryStrings("SELECT catalog_id FROM fx_rates;"), [])
        XCTAssertEqual(try database.queryStrings("SELECT canonical_model_id FROM price_rates;"), [])
    }

    func testLatestAppliedCatalogReturnsNewestCanonicalJSONAndNilBeforeImport() async throws {
        let ledger = try makeLedger()
        try await ledger.migrate()
        let before = try await ledger.latestAppliedPricingCatalogJSON()
        XCTAssertNil(before)
        let first = try catalog(id: "catalog-first", models: [model()])
        let second = try catalog(id: "catalog-second", models: [model(
            canonicalModelID: "gpt-second",
            observedModelID: "gpt-second"
        )])

        try await apply(first, to: ledger)
        try await apply(second, to: ledger)

        let latest = try await ledger.latestAppliedPricingCatalogJSON()
        XCTAssertEqual(latest, second.canonicalJSON)
    }

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

    func testLaterRateInsertFailureRollsBackEarlierRowsAndCatalogImport() async throws {
        let setup = try makeLedgerWithDatabase()
        try await setup.ledger.migrate()
        try await apply(
            try catalog(id: "catalog-a", models: [model(
                canonicalModelID: "m-existing",
                observedModelID: "m-existing"
            )]),
            to: setup.ledger
        )
        let before = try await setup.ledger.pricingSnapshot()
        let database = try SQLiteConnection(url: setup.databaseURL)
        let beforeDatabaseBytes = try pricingDatabaseBytes(in: database)
        try database.execute("""
        CREATE TRIGGER reject_z_trigger_rate
        BEFORE INSERT ON price_rates
        FOR EACH ROW WHEN NEW.canonical_model_id = 'z-trigger'
          AND EXISTS(SELECT 1 FROM price_rates WHERE canonical_model_id = 'a-new')
        BEGIN
          SELECT RAISE(ABORT, 'injected rate failure');
        END;
        """)
        let candidate = try catalog(id: "catalog-b", models: [
            model(canonicalModelID: "a-new", observedModelID: "a-new"),
            model(canonicalModelID: "z-trigger", observedModelID: "z-trigger")
        ])

        await assertSQLiteConstraint(containing: "injected rate failure") {
            try await self.apply(candidate, to: setup.ledger)
        }

        let afterFailure = try await setup.ledger.pricingSnapshot()
        XCTAssertEqual(afterFailure, before)
        XCTAssertEqual(try pricingDatabaseBytes(in: database), beforeDatabaseBytes)
        try assertOnlyExistingCatalogRows(in: database)
    }

    func testLaterAliasInsertFailureRollsBackEarlierRowsAndCatalogImport() async throws {
        let setup = try makeLedgerWithDatabase()
        try await setup.ledger.migrate()
        try await apply(
            try catalog(id: "catalog-a", models: [model(
                canonicalModelID: "m-existing",
                observedModelID: "m-existing"
            )]),
            to: setup.ledger
        )
        let before = try await setup.ledger.pricingSnapshot()
        let database = try SQLiteConnection(url: setup.databaseURL)
        let beforeDatabaseBytes = try pricingDatabaseBytes(in: database)
        try database.execute("""
        CREATE TRIGGER reject_z_trigger_alias
        BEFORE INSERT ON model_aliases
        FOR EACH ROW WHEN NEW.observed_model_id = 'z-trigger'
          AND EXISTS(SELECT 1 FROM model_aliases WHERE observed_model_id = 'a-new')
        BEGIN
          SELECT RAISE(ABORT, 'injected alias failure');
        END;
        """)
        let candidate = try catalog(id: "catalog-b", models: [
            model(canonicalModelID: "a-new", observedModelID: "a-new"),
            model(canonicalModelID: "z-trigger", observedModelID: "z-trigger")
        ])

        await assertSQLiteConstraint(containing: "injected alias failure") {
            try await self.apply(candidate, to: setup.ledger)
        }

        let afterFailure = try await setup.ledger.pricingSnapshot()
        XCTAssertEqual(afterFailure, before)
        XCTAssertEqual(try pricingDatabaseBytes(in: database), beforeDatabaseBytes)
        try assertOnlyExistingCatalogRows(in: database)
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
        try makeLedgerWithDatabase().ledger
    }

    private func makeLedgerWithDatabase() throws -> (ledger: SQLiteLedger, databaseURL: URL) {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let databaseURL = directory.appending(path: "ledger.sqlite")
        let ledger = try SQLiteLedger(
            databaseURL: databaseURL,
            backupDirectory: directory.appending(path: "Backups")
        )
        return (ledger: ledger, databaseURL: databaseURL)
    }

    private func assertOnlyExistingCatalogRows(
        in database: SQLiteConnection,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        XCTAssertEqual(
            try database.queryStrings("SELECT DISTINCT canonical_model_id FROM price_rates ORDER BY canonical_model_id;"),
            ["m-existing"],
            file: file,
            line: line
        )
        XCTAssertEqual(
            try database.queryStrings("SELECT DISTINCT canonical_model_id FROM model_aliases ORDER BY canonical_model_id;"),
            ["m-existing"],
            file: file,
            line: line
        )
        XCTAssertEqual(
            try database.queryStrings("SELECT catalog_id FROM catalog_imports ORDER BY catalog_id;"),
            ["catalog-a"],
            file: file,
            line: line
        )
    }

    private func pricingDatabaseBytes(in database: SQLiteConnection) throws -> Data {
        let rows = try database.queryStrings("""
        SELECT 'alias|' || quote(provider) || '|' || quote(observed_model_id) || '|'
               || quote(canonical_model_id) || '|' || quote(effective_from) || '|'
               || quote(effective_to) || '|' || quote(catalog_id)
        FROM model_aliases
        ORDER BY provider, observed_model_id, effective_from;
        """) + database.queryStrings("""
        SELECT 'rate|' || quote(provider) || '|' || quote(canonical_model_id) || '|'
               || quote(metric) || '|' || quote(usd_per_million) || '|' || quote(effective_from) || '|'
               || quote(effective_to) || '|' || quote(provenance_url) || '|' || quote(verified_at) || '|'
               || quote(catalog_id)
        FROM price_rates
        ORDER BY provider, canonical_model_id, metric, effective_from;
        """) + database.queryStrings("""
        SELECT 'import|' || quote(catalog_id) || '|' || quote(schema_version) || '|'
               || quote(origin) || '|' || quote(imported_at) || '|' || quote(applied) || '|'
               || quote(validation_summary) || '|' || hex(canonical_json)
        FROM catalog_imports
        ORDER BY catalog_id;
        """)
        return Data(rows.joined(separator: "\n").utf8)
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

    private func catalogV2(
        id: String,
        eur: String = "0.866926745"
    ) throws -> ValidatedPricingCatalog {
        try PricingCatalogValidator().validate(PricingCatalog(
            schemaVersion: 2,
            catalogID: id,
            generatedAt: "2026-08-07T12:00:00Z",
            origin: CatalogOrigin(kind: .officialResearch, url: "https://openai.com/api/pricing/"),
            models: [model()],
            exchangeRates: CatalogExchangeRateSnapshot(
                baseCurrency: "USD",
                effectiveDate: "2026-08-07",
                verifiedAt: "2026-08-07",
                provenanceURL: "https://www.ecb.europa.eu/stats/eurofxref/eurofxref-daily.xml",
                rates: [
                    "USD": DecimalString(decimal: 1),
                    "EUR": DecimalString(decimal: Decimal(string: eur)!),
                    "JPY": DecimalString(decimal: Decimal(string: "158.33550065")!),
                    "GBP": DecimalString(decimal: Decimal(string: "0.743519723")!),
                    "CNY": DecimalString(decimal: Decimal(string: "6.747637625")!)
                ]
            )
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
            validationSummary: catalog.schemaVersion == 1
                ? PricingImportMetadata.schemaV1ValidSummary
                : PricingImportMetadata.schemaV2ValidSummary
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

    private func assertSQLiteConstraint(
        containing expectedMessage: String,
        file: StaticString = #filePath,
        line: UInt = #line,
        operation: () async throws -> Void
    ) async {
        do {
            try await operation()
            XCTFail("expected SQLite constraint failure", file: file, line: line)
        } catch let error as SQLiteFailure {
            XCTAssertEqual(error.code, 19, file: file, line: line)
            XCTAssertTrue(error.message.contains(expectedMessage), file: file, line: line)
        } catch {
            XCTFail("expected SQLite constraint failure, received \(error)", file: file, line: line)
        }
    }
}

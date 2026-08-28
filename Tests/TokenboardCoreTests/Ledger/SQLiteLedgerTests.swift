import Foundation
import CSQLite
import Darwin
import XCTest
@testable import TokenboardCore

final class SQLiteLedgerTests: XCTestCase {
    func testFixedRecoveryImageFailsWithSQLiteFullBeforeGrowingPastCapacity() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = directory.appending(path: "growth.sqlite")
        let source = try SQLiteConnection(url: database)
        try source.execute("PRAGMA journal_mode = DELETE;")
        try source.execute("CREATE TABLE growth(value BLOB NOT NULL);")
        try source.close()
        let descriptor = Darwin.open(database.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { throw SQLiteGrowthInvariantError.openFailed }
        defer { Darwin.close(descriptor) }
        var information = stat()
        guard fstat(descriptor, &information) == 0,
              let byteCount = Int(exactly: information.st_size) else {
            throw SQLiteGrowthInvariantError.statFailed
        }
        let recovery = try SQLiteConnection.recoveryConnection(
            descriptor: descriptor,
            byteCount: byteCount,
            maximumBytes: byteCount
        )
        defer { try? recovery.close() }

        do {
            try recovery.execute("INSERT INTO growth VALUES(zeroblob(1048576));")
            throw SQLiteGrowthInvariantError.growthEscapedLimit
        } catch let failure as SQLiteFailure {
            guard failure.code == SQLITE_FULL else { throw failure }
        }
    }

    func testTruncateCheckpointAcceptsOnlyDocumentedCompleteResultShapes() {
        XCTAssertTrue(SQLiteConnection.isCompleteTruncateCheckpoint(
            result: SQLITE_OK,
            logFrames: -1,
            checkpointedFrames: -1
        ))
        XCTAssertTrue(SQLiteConnection.isCompleteTruncateCheckpoint(
            result: SQLITE_OK,
            logFrames: 0,
            checkpointedFrames: 0
        ))
        XCTAssertFalse(SQLiteConnection.isCompleteTruncateCheckpoint(
            result: SQLITE_OK,
            logFrames: 3,
            checkpointedFrames: 3
        ))
        XCTAssertFalse(SQLiteConnection.isCompleteTruncateCheckpoint(
            result: SQLITE_BUSY,
            logFrames: 0,
            checkpointedFrames: 0
        ))
    }

    private let fingerprintA = String(repeating: "a", count: 64)
    private let fingerprintB = String(repeating: "b", count: 64)
    private let recordHash = String(repeating: "c", count: 64)
    private let lineHash = String(repeating: "d", count: 64)

    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func makeLedger(in directory: URL? = nil) throws -> (SQLiteLedger, URL) {
        let directory = try directory ?? makeDirectory()
        return (
            try SQLiteLedger(
                databaseURL: directory.appending(path: "ledger.sqlite"),
                backupDirectory: directory.appending(path: "Backups")
            ),
            directory
        )
    }

    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(identifier: "Europe/Amsterdam")!
        value.firstWeekday = 2
        return value
    }

    private func timestamp(_ value: String = "2026-08-05T10:00:00Z") -> Date {
        ISO8601DateFormatter().date(from: value)!
    }

    private func usage(
        timestamp: Date? = nil,
        modelID: String = "gpt-test",
        quantity: Int64 = 100
    ) throws -> NormalizedUsage {
        try NormalizedUsage(
            provider: .codex,
            observedModelID: modelID,
            timestamp: timestamp ?? self.timestamp(),
            metrics: [.inputUncached: quantity],
            stableSourceID: "session-a",
            stableUsageID: "turn-a"
        )
    }

    private func checkpoint(
        fingerprint: String? = nil,
        provider: Provider = .codex,
        timestamp: Date? = nil,
        byteOffset: Int64 = 120,
        lastUsageIdentityHash: String? = nil,
        lastCommittedLineHash: String? = nil,
        adapterState: [String: String] = ["current_model": "gpt-test"]
    ) -> SourceCheckpoint {
        SourceCheckpoint(
            fingerprint: fingerprint ?? fingerprintA,
            provider: provider,
            parserVersion: 1,
            byteOffset: byteOffset,
            fileSize: 120,
            modificationTime: timestamp ?? self.timestamp(),
            lastUsageIdentityHash: lastUsageIdentityHash,
            lastCommittedLineHash: lastCommittedLineHash ?? lineHash,
            cumulativeMetrics: [.inputUncached: 100, .output: 20],
            adapterState: adapterState
        )
    }

    private func skippedRecord(
        fingerprint: String? = nil,
        recordHash: String? = nil,
        reason: String = "malformed_record"
    ) -> SkippedRecord {
        SkippedRecord(
            sourceFingerprint: fingerprint ?? fingerprintA,
            byteOffset: 12,
            recordHash: recordHash ?? self.recordHash,
            parserVersion: 1,
            reason: reason
        )
    }

    func testIntegrityCheckAcceptsAMigratedLedger() async throws {
        let (ledger, _) = try makeLedger()
        try await ledger.migrate()

        try await ledger.integrityCheck()
    }

    func testLifetimeAdditiveTokenTotalExcludesInformationalSubsets() async throws {
        let (ledger, directory) = try makeLedger()
        defer { try? FileManager.default.removeItem(at: directory) }
        try await ledger.migrate()
        let entry = try NormalizedUsage(
            provider: .codex,
            observedModelID: "gpt-test",
            timestamp: timestamp(),
            metrics: [
                .inputUncached: 125,
                .output: 25,
                .detailReasoningOutput: 1_000
            ],
            stableSourceID: "session-a",
            stableUsageID: "turn-a"
        )
        try await ledger.commit(
            [entry],
            skipped: [],
            checkpoint: checkpoint(),
            calendar: calendar
        )

        let total = try await ledger.lifetimeAdditiveTokenTotal()
        XCTAssertEqual(total, 150)
    }

    func testIntegrityCheckRejectsATruncatedLedger() async throws {
        let (ledger, directory) = try makeLedger()
        try await ledger.migrate()
        let database = directory.appending(path: "ledger.sqlite")
        let connection = try SQLiteConnection(url: database)
        try connection.execute("PRAGMA wal_checkpoint(TRUNCATE);")
        let handle = try FileHandle(forWritingTo: database)
        try handle.truncate(atOffset: 512)
        try handle.close()

        do {
            try await ledger.integrityCheck()
            XCTFail("expected a truncated ledger to fail its integrity check")
        } catch is SQLiteFailure {
        } catch is LedgerError {
        }
    }

    private func assertStorageValidationError(
        _ operation: () async throws -> Void,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            try await operation()
            XCTFail("Expected storage validation failure", file: file, line: line)
        } catch is LedgerValidationError {
        } catch {
            XCTFail("Expected LedgerValidationError, received \(error)", file: file, line: line)
        }
    }

    func testCommitAggregatesSameDayAndStoresCheckpointAtomically() async throws {
        let (ledger, _) = try makeLedger()
        try await ledger.migrate()
        let timestamp = timestamp()
        let usage = try NormalizedUsage(
            provider: .codex,
            observedModelID: "gpt-test",
            timestamp: timestamp,
            metrics: [.inputUncached: 100, .output: 20, .detailReasoningOutput: 5],
            stableSourceID: "session-a",
            stableUsageID: "turn-a"
        )
        let checkpoint = checkpoint(timestamp: timestamp)

        try await ledger.commit([usage, usage], skipped: [], checkpoint: checkpoint, calendar: calendar)

        let rows = try await ledger.usageRows(in: nil, calendar: calendar)
        XCTAssertEqual(rows.first(where: { $0.metric == .inputUncached })?.quantity, 200)
        XCTAssertEqual(rows.first(where: { $0.metric == .detailReasoningOutput })?.aggregation, .informationalSubset)
        let storedCheckpoint = try await ledger.checkpoint(for: fingerprintA)
        XCTAssertEqual(storedCheckpoint, checkpoint)
    }

    func testCommitAggregatesUsageIntoCalendarHourBuckets() async throws {
        let (ledger, _) = try makeLedger()
        try await ledger.migrate()
        let usage = try [
            self.usage(timestamp: timestamp("2026-08-11T07:05:00Z"), quantity: 100),
            self.usage(timestamp: timestamp("2026-08-11T07:55:00Z"), quantity: 50),
            self.usage(timestamp: timestamp("2026-08-11T08:00:00Z"), quantity: 25),
        ]

        try await ledger.commit(
            usage,
            skipped: [],
            checkpoint: checkpoint(),
            calendar: calendar
        )

        let rows = try await ledger.hourlyUsageRows(in: nil, calendar: calendar)

        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows.map(\.quantity), [150, 25])
        XCTAssertEqual(rows.map { calendar.component(.hour, from: $0.hourStart) }, [9, 10])
    }

    func testHourlyCoverageBeginsAtMigrationUntilOlderHistoryIsImported() async throws {
        let (ledger, directory) = try makeLedger()
        defer { try? FileManager.default.removeItem(at: directory) }
        let beforeMigration = Date()
        try await ledger.migrate()
        let connection = try SQLiteConnection(url: directory.appending(path: "ledger.sqlite"))
        XCTAssertEqual(
            try connection.queryStrings("SELECT version FROM schema_migrations ORDER BY version;"),
            ["1", "2", "3", "4"]
        )
        XCTAssertEqual(
            try connection.queryStrings("SELECT applied_at FROM schema_migrations WHERE version = 4;" ).count,
            1
        )
        let queriedInitialCoverage = try await ledger.hourlyUsageCoverageStart()
        let initialCoverage = try XCTUnwrap(queriedInitialCoverage)

        XCTAssertGreaterThanOrEqual(initialCoverage, beforeMigration.addingTimeInterval(-1))

        let historical = timestamp("2020-01-02T10:15:00Z")
        try await ledger.commit(
            [try usage(timestamp: historical)],
            skipped: [],
            checkpoint: checkpoint(timestamp: historical),
            calendar: calendar
        )

        let queriedImportedCoverage = try await ledger.hourlyUsageCoverageStart()
        let importedCoverage = try XCTUnwrap(queriedImportedCoverage)
        XCTAssertEqual(importedCoverage, calendar.dateInterval(of: .hour, for: historical)?.start)
    }

    func testMissingSourceNeverDeletesCommittedRows() async throws {
        let (ledger, _) = try makeLedger()
        try await ledger.migrate()
        let expectedUsage = try usage()
        try await ledger.commit([expectedUsage], skipped: [], checkpoint: checkpoint(), calendar: calendar)

        let firstRead = try await ledger.usageRows(in: nil, calendar: calendar)
        let secondRead = try await ledger.usageRows(in: nil, calendar: calendar)
        let storedCheckpoint = try await ledger.checkpoint(for: fingerprintA)
        XCTAssertEqual(firstRead, secondRead)
        XCTAssertEqual(firstRead.first?.quantity, 100)
        XCTAssertEqual(storedCheckpoint, checkpoint())
    }

    func testInvalidCheckpointRollsBackUsageAndSkippedRecords() async throws {
        let (ledger, directory) = try makeLedger()
        try await ledger.migrate()
        let invalidCheckpoint = checkpoint(byteOffset: -1)

        do {
            try await ledger.commit([try usage()], skipped: [skippedRecord()], checkpoint: invalidCheckpoint, calendar: calendar)
            XCTFail("Expected invalid checkpoint to fail its SQLite constraint")
        } catch let failure as SQLiteFailure {
            XCTAssertEqual(failure.code, 19)
        } catch {
            XCTFail("Expected SQLiteFailure, received \(error)")
        }

        let rows = try await ledger.usageRows(in: nil, calendar: calendar)
        let checkpoint = try await ledger.checkpoint(for: fingerprintA)
        XCTAssertEqual(rows, [])
        XCTAssertNil(checkpoint)
        let connection = try SQLiteConnection(url: directory.appending(path: "ledger.sqlite"))
        XCTAssertEqual(try connection.queryStrings("SELECT record_hash FROM skipped_records;"), [])
    }

    func testSkippedRecordCountReportsOnlyCommittedUniqueDiagnostics() async throws {
        let (ledger, _) = try makeLedger()
        try await ledger.migrate()
        let first = skippedRecord()
        let second = SkippedRecord(
            sourceFingerprint: fingerprintA,
            byteOffset: 13,
            recordHash: String(repeating: "e", count: 64),
            parserVersion: 1,
            reason: "missing_model"
        )

        try await ledger.commit(
            [],
            skipped: [first, first, second],
            checkpoint: checkpoint(),
            calendar: calendar
        )

        let skippedRecordCount = try await ledger.skippedRecordCount()
        XCTAssertEqual(skippedRecordCount, 2)
    }

    func testSkippedRecordCountsPersistByCheckpointProvider() async throws {
        let (ledger, directory) = try makeLedger()
        defer { try? FileManager.default.removeItem(at: directory) }
        try await ledger.migrate()
        try await ledger.commit(
            [],
            skipped: [skippedRecord()],
            checkpoint: checkpoint(provider: .codex),
            calendar: calendar
        )
        try await ledger.commit(
            [],
            skipped: [skippedRecord(
                fingerprint: fingerprintB,
                recordHash: String(repeating: "e", count: 64)
            )],
            checkpoint: checkpoint(fingerprint: fingerprintB, provider: .claudeCode),
            calendar: calendar
        )
        try await ledger.shutdown()

        let reopened = try SQLiteLedger(
            databaseURL: directory.appending(path: "ledger.sqlite"),
            backupDirectory: directory.appending(path: "Backups")
        )
        try await reopened.migrate()
        let counts = try await reopened.skippedRecordCountsByProvider()

        XCTAssertEqual(counts, [.codex: 1, .claudeCode: 1])
        try await reopened.shutdown()
    }

    func testExistingQuantityOverflowRollsBackUsageSkippedRecordsAndCheckpoint() async throws {
        let (ledger, directory) = try makeLedger()
        try await ledger.migrate()
        try await ledger.commit(
            [try usage(quantity: .max)],
            skipped: [],
            checkpoint: checkpoint(),
            calendar: calendar
        )

        do {
            try await ledger.commit(
                [try usage(quantity: 1)],
                skipped: [skippedRecord()],
                checkpoint: checkpoint(fingerprint: fingerprintB),
                calendar: calendar
            )
            XCTFail("Expected SQLite integer-storage constraint to reject overflow")
        } catch let failure as SQLiteFailure {
            XCTAssertNotEqual(failure.code, 0)
        }

        let rows = try await ledger.usageRows(in: nil, calendar: calendar)
        XCTAssertEqual(rows.first?.quantity, .max)
        let overflowCheckpoint = try await ledger.checkpoint(for: fingerprintB)
        XCTAssertNil(overflowCheckpoint)
        let connection = try SQLiteConnection(url: directory.appending(path: "ledger.sqlite"))
        XCTAssertEqual(try connection.queryStrings("SELECT record_hash FROM skipped_records;"), [])
    }

    func testPrivacyBoundaryRejectsUnsafeContentBeforePersistence() async throws {
        let (ledger, directory) = try makeLedger()
        try await ledger.migrate()
        let calendar = calendar

        await assertStorageValidationError {
            try await ledger.commit(
                [try self.usage(modelID: "prompt\ncontents")],
                skipped: [],
                checkpoint: self.checkpoint(),
                calendar: calendar
            )
        }
        await assertStorageValidationError {
            try await ledger.commit(
                [try self.usage()],
                skipped: [self.skippedRecord(reason: "/private/session/path")],
                checkpoint: self.checkpoint(),
                calendar: calendar
            )
        }
        await assertStorageValidationError {
            try await ledger.commit(
                [try self.usage()],
                skipped: [],
                checkpoint: self.checkpoint(fingerprint: "fingerprint-a"),
                calendar: calendar
            )
        }
        await assertStorageValidationError {
            try await ledger.commit(
                [try self.usage()],
                skipped: [],
                checkpoint: self.checkpoint(lastCommittedLineHash: "line-hash"),
                calendar: calendar
            )
        }
        await assertStorageValidationError {
            try await ledger.commit(
                [try self.usage()],
                skipped: [SkippedRecord(
                    sourceFingerprint: self.fingerprintA,
                    byteOffset: 12,
                    recordHash: "record-hash",
                    parserVersion: 1,
                    reason: "malformed_record"
                )],
                checkpoint: self.checkpoint(),
                calendar: calendar
            )
        }
        await assertStorageValidationError {
            try await ledger.commit(
                [try self.usage()],
                skipped: [SkippedRecord(
                    sourceFingerprint: "source-fingerprint",
                    byteOffset: 12,
                    recordHash: self.recordHash,
                    parserVersion: 1,
                    reason: "malformed_record"
                )],
                checkpoint: self.checkpoint(),
                calendar: calendar
            )
        }
        await assertStorageValidationError {
            try await ledger.commit(
                [try self.usage()],
                skipped: [],
                checkpoint: self.checkpoint(lastUsageIdentityHash: "identity-hash"),
                calendar: calendar
            )
        }
        await assertStorageValidationError {
            try await ledger.commit(
                [try self.usage()],
                skipped: [],
                checkpoint: self.checkpoint(adapterState: ["source_path": "/private/session/path"]),
                calendar: calendar
            )
        }
        await assertStorageValidationError {
            try await ledger.commit(
                [try self.usage(modelID: "gpt\u{0000}test")],
                skipped: [],
                checkpoint: self.checkpoint(),
                calendar: calendar
            )
        }

        let rows = try await ledger.usageRows(in: nil, calendar: calendar)
        let storedCheckpoint = try await ledger.checkpoint(for: fingerprintA)
        XCTAssertEqual(rows, [])
        XCTAssertNil(storedCheckpoint)
        let connection = try SQLiteConnection(url: directory.appending(path: "ledger.sqlite"))
        XCTAssertEqual(try connection.queryStrings("SELECT record_hash FROM skipped_records;"), [])
    }

    func testPrivacyBoundaryRejectsUnsafeCurrentModelValuesWithoutPersistence() async throws {
        let (ledger, directory) = try makeLedger()
        try await ledger.migrate()
        let connection = try SQLiteConnection(url: directory.appending(path: "ledger.sqlite"))
        let unsafeModels = [
            "/private/session/path",
            "../session-a",
            "https://example.test/repo",
            "raw prompt words",
            "<not-synthetic>"
        ]

        for (index, modelID) in unsafeModels.enumerated() {
            let fingerprint = String(repeating: String(index), count: 64)
            await assertStorageValidationError {
                try await ledger.commit(
                    [try self.usage()],
                    skipped: [self.skippedRecord()],
                    checkpoint: self.checkpoint(
                        fingerprint: fingerprint,
                        adapterState: ["current_model": modelID]
                    ),
                    calendar: self.calendar
                )
            }

            let rows = try await ledger.usageRows(in: nil, calendar: calendar)
            let checkpoint = try await ledger.checkpoint(for: fingerprint)
            XCTAssertEqual(rows, [])
            XCTAssertNil(checkpoint)
            XCTAssertEqual(try connection.queryStrings("SELECT record_hash FROM skipped_records;"), [])
        }
    }

    func testIdentifierShapedCurrentModelsRemainCountable() async throws {
        let (ledger, _) = try makeLedger()
        try await ledger.migrate()
        let models = ["gpt-5.6-sol", "claude-opus-5", "<synthetic>"]
        let fingerprints = ["e", "f", "0"].map { String(repeating: $0, count: 64) }

        for (modelID, fingerprint) in zip(models, fingerprints) {
            try await ledger.commit(
                [try usage(modelID: modelID)],
                skipped: [],
                checkpoint: checkpoint(
                    fingerprint: fingerprint,
                    adapterState: ["current_model": modelID]
                ),
                calendar: calendar
            )
        }

        let rows = try await ledger.usageRows(in: nil, calendar: calendar)
        XCTAssertEqual(Set(rows.map(\.observedModelID)), Set(models))
    }

    func testSaltIsStableAfterReopeningAndProviderFingerprintsAreSeparated() async throws {
        let directory = try makeDirectory()
        let (ledger, _) = try makeLedger(in: directory)
        try await ledger.migrate()
        let codexFingerprint = try await ledger.sourceFingerprint(provider: .codex, stableID: "session-a")
        let claudeFingerprint = try await ledger.sourceFingerprint(provider: .claudeCode, stableID: "session-a")
        XCTAssertNotEqual(codexFingerprint, claudeFingerprint)

        let (reopened, _) = try makeLedger(in: directory)
        try await reopened.migrate()
        let reopenedFingerprint = try await reopened.sourceFingerprint(provider: .codex, stableID: "session-a")
        XCTAssertEqual(codexFingerprint, reopenedFingerprint)
    }

    func testIntervalUsesLocalDaysAcrossDSTBoundary() async throws {
        let (ledger, _) = try makeLedger()
        try await ledger.migrate()
        let firstTimestamp = timestamp("2026-03-29T00:30:00Z")
        let secondTimestamp = timestamp("2026-03-30T00:30:00Z")
        try await ledger.commit(
            [try usage(timestamp: firstTimestamp)],
            skipped: [],
            checkpoint: checkpoint(timestamp: firstTimestamp),
            calendar: calendar
        )
        try await ledger.commit(
            [try usage(timestamp: secondTimestamp)],
            skipped: [],
            checkpoint: checkpoint(timestamp: secondTimestamp),
            calendar: calendar
        )

        var dayComponents = DateComponents()
        dayComponents.year = 2026
        dayComponents.month = 3
        dayComponents.day = 29
        let start = calendar.date(from: dayComponents)!
        let followingDay = calendar.date(byAdding: .day, value: 1, to: start)!
        let end = calendar.date(byAdding: .day, value: 2, to: start)!
        let firstDay = try await ledger.usageRows(in: DateInterval(start: start, end: followingDay), calendar: calendar)
        let bothDays = try await ledger.usageRows(in: DateInterval(start: start, end: end), calendar: calendar)
        XCTAssertEqual(firstDay.count, 1)
        XCTAssertEqual(bothDays.count, 2)
    }

    func testTextBinderPreservesEmbeddedNULAndMultibyteValues() throws {
        let directory = try makeDirectory()
        let connection = try SQLiteConnection(url: directory.appending(path: "ledger.sqlite"))
        let value = "safe\u{0000}multibyte-✓"
        XCTAssertEqual(try connection.textBindingRoundTripForTesting(value), value)
    }
}

private enum SQLiteGrowthInvariantError: Error {
    case openFailed
    case statFailed
    case growthEscapedLimit
}

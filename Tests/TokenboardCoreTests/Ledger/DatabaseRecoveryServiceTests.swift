import Foundation
import CSQLite
import Darwin
import XCTest
@testable import TokenboardCore

final class DatabaseRecoveryServiceTests: XCTestCase {
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(identifier: "Europe/Amsterdam")!
        return value
    }

    func testShutdownIsConcurrentSafeIdempotentAndClosesEveryLaterOperation() async throws {
        let setup = try await makePopulatedLedger(quantity: 37)
        defer { try? FileManager.default.removeItem(at: setup.directory) }

        await withTaskGroup(of: Error?.self) { group in
            for _ in 0..<4 {
                group.addTask {
                    do {
                        try await setup.ledger.shutdown()
                        return nil
                    } catch {
                        return error
                    }
                }
            }
            for await error in group {
                XCTAssertNil(error)
            }
        }
        try await setup.ledger.shutdown()

        await assertConnectionClosed { try await setup.ledger.migrate() }
        await assertConnectionClosed { try await setup.ledger.integrityCheck() }
        await assertConnectionClosed {
            _ = try await setup.ledger.usageRows(in: nil, calendar: self.calendar)
        }
        await assertConnectionClosed {
            _ = try await setup.ledger.sourceFingerprint(provider: .codex, stableID: "session")
        }
    }

    func testBusyWALCheckpointBlocksRestoreUntilReaderReleasesAndRetrySucceeds() async throws {
        let setup = try await makePopulatedLedger(quantity: 79)
        defer { try? FileManager.default.removeItem(at: setup.directory) }
        try await setup.ledger.shutdown()
        let backups = setup.directory.appending(path: "Backups", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: backups, withIntermediateDirectories: true)
        let backup = backups.appending(path: "ledger-v1-100.sqlite")
        try Data(contentsOf: setup.database).write(to: backup)
        let writer = try SQLiteLedger(databaseURL: setup.database, backupDirectory: backups)
        try await writer.migrate()
        let reader = try SQLiteConnection(url: setup.database)
        try reader.execute("BEGIN;")
        _ = try reader.queryStrings("SELECT quantity FROM daily_usage;")
        try await writer.commit(
            [try NormalizedUsage(
                provider: .codex,
                observedModelID: "gpt-test",
                timestamp: ISO8601DateFormatter().date(from: "2026-08-05T10:01:00Z")!,
                metrics: [.inputUncached: 11],
                stableSourceID: "content-free-source",
                stableUsageID: "content-free-usage-2"
            )],
            skipped: [],
            checkpoint: SourceCheckpoint(
                fingerprint: String(repeating: "a", count: 64),
                provider: .codex,
                parserVersion: 1,
                byteOffset: 2,
                fileSize: 2,
                modificationTime: nil,
                lastUsageIdentityHash: String(repeating: "e", count: 64),
                lastCommittedLineHash: String(repeating: "f", count: 64),
                cumulativeMetrics: [:],
                adapterState: ["current_model": "gpt-test"]
            ),
            calendar: calendar
        )
        let service = DatabaseRecoveryService(
            databaseURL: setup.database,
            backupDirectory: backups
        )
        let available = try await service.availableBackups()
        let confirmed = try XCTUnwrap(available.first)

        do {
            _ = try await service.restore(confirmed) {
                try await writer.shutdown()
            }
            XCTFail("busy WAL checkpoint incorrectly allowed restore")
        } catch let failure as SQLiteFailure {
            XCTAssertEqual(failure.code, SQLITE_BUSY)
        }
        let rowsWhileBlocked = try await writer.usageRows(in: nil, calendar: calendar)
        XCTAssertEqual(rowsWhileBlocked.reduce(0) { $0 + $1.quantity }, 90)
        let residueWhileBlocked = try FileManager.default.contentsOfDirectory(
            atPath: setup.directory.path
        )
        XCTAssertFalse(residueWhileBlocked.contains { $0.hasPrefix(".tokenboard-") })

        try reader.execute("COMMIT;")
        try reader.close()
        _ = try await service.restore(confirmed) {
            try await writer.shutdown()
        }

        let restored = try SQLiteLedger(databaseURL: setup.database, backupDirectory: backups)
        try await restored.migrate()
        let restoredRows = try await restored.usageRows(in: nil, calendar: calendar)
        XCTAssertEqual(restoredRows.reduce(0) { $0 + $1.quantity }, 79)
        try await restored.shutdown()
    }

    func testAvailableBackupsFiltersStrictlyAndSortsByModificationDateThenName() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = directory.appending(path: "ledger.sqlite")
        let backups = directory.appending(path: "Backups", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: backups, withIntermediateDirectories: true)
        try Data("database".utf8).write(to: database)

        let oldest = backups.appending(path: "ledger-v1-100.sqlite")
        let tiedA = backups.appending(path: "ledger-v1-200.sqlite")
        let tiedB = backups.appending(path: "ledger-v2-200.sqlite")
        let impostors = [
            backups.appending(path: "ledger-v1-300.sqlite-wal"),
            backups.appending(path: "ledger-vx-300.sqlite"),
            backups.appending(path: "prefix-ledger-v1-300.sqlite"),
            backups.appending(path: "ledger-v1-300.sqlite.backup")
        ]
        let validBytes = try await databaseBytes(quantity: 19)
        for file in [oldest, tiedA, tiedB] {
            try validBytes.write(to: file)
        }
        for file in impostors {
            try Data(file.lastPathComponent.utf8).write(to: file)
        }
        let invalidLegacy = backups.appending(path: "ledger-v1-300.sqlite")
        let invalidCanonical = backups.appending(
            path: "ledger-v1-300-00000000-0000-4000-8000-000000000006.sqlite"
        )
        let invalidBytes = Data("regular-file-lookalike".utf8)
        try invalidBytes.write(to: invalidLegacy)
        try invalidBytes.write(to: invalidCanonical)
        try setModificationDate(Date(timeIntervalSince1970: 100), for: oldest)
        try setModificationDate(Date(timeIntervalSince1970: 200), for: tiedA)
        try setModificationDate(Date(timeIntervalSince1970: 200), for: tiedB)
        for file in impostors {
            try setModificationDate(Date(timeIntervalSince1970: 300), for: file)
        }
        try setModificationDate(Date(timeIntervalSince1970: 300), for: invalidLegacy)
        try setModificationDate(Date(timeIntervalSince1970: 300), for: invalidCanonical)

        let service = DatabaseRecoveryService(databaseURL: database, backupDirectory: backups)
        let result = try await service.availableBackups()

        XCTAssertEqual(result.map(\.filename), [
            "ledger-v2-200.sqlite",
            "ledger-v1-200.sqlite",
            "ledger-v1-100.sqlite"
        ])
        XCTAssertEqual(try Data(contentsOf: invalidLegacy), invalidBytes)
        XCTAssertEqual(try Data(contentsOf: invalidCanonical), invalidBytes)
    }

    func testAvailableBackupsRejectsAnUnboundedCandidateInventory() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = directory.appending(path: "ledger.sqlite")
        let backups = directory.appending(path: "Backups", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: backups, withIntermediateDirectories: true)
        try Data("database".utf8).write(to: database)
        for index in 0...DatabaseRecoveryService.maximumBackupCandidates {
            try Data().write(to: backups.appending(path: "ledger-v1-\(index).sqlite"))
        }
        let service = DatabaseRecoveryService(databaseURL: database, backupDirectory: backups)

        await assertRecoveryError(.backupInventoryTooLarge(
            maximumCandidates: DatabaseRecoveryService.maximumBackupCandidates
        )) {
            _ = try await service.availableBackups()
        }
    }

    func testRestoreWaitsForShutdownThenRestoresLatestValidRows() async throws {
        let setup = try await makePopulatedLedger(quantity: 41)
        defer { try? FileManager.default.removeItem(at: setup.directory) }
        let backups = setup.directory.appending(path: "Backups", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: backups, withIntermediateDirectories: true)
        try await setup.ledger.shutdown()
        let expectedBytes = try Data(contentsOf: setup.database)
        let backup = backups.appending(path: "ledger-v1-100.sqlite")
        try expectedBytes.write(to: backup)

        let corruptingLedger = try SQLiteLedger(databaseURL: setup.database, backupDirectory: backups)
        let handle = try FileHandle(forWritingTo: setup.database)
        try handle.truncate(atOffset: 256)
        try handle.close()
        await XCTAssertThrowsErrorAsync { try await corruptingLedger.integrityCheck() }
        let wal = setup.directory.appending(path: "ledger.sqlite-wal")
        let shm = setup.directory.appending(path: "ledger.sqlite-shm")
        let lookalike = setup.directory.appending(path: "ledger.sqlite-wal.keep")

        let gate = RecoveryGate()
        let service = DatabaseRecoveryService(databaseURL: setup.database, backupDirectory: backups)
        let available = try await service.availableBackups()
        let confirmed = try XCTUnwrap(available.first)
        let restore = Task {
            try await service.restore(confirmed) {
                await gate.enter()
                await gate.wait()
                try await corruptingLedger.shutdown()
                try? FileManager.default.removeItem(at: wal)
                try? FileManager.default.removeItem(at: shm)
                try Data("wal".utf8).write(to: wal, options: .atomic)
                try Data("shm".utf8).write(to: shm, options: .atomic)
                try Data("keep".utf8).write(to: lookalike, options: .atomic)
            }
        }
        await gate.waitUntilEntered()
        XCTAssertNotEqual(try Data(contentsOf: setup.database), expectedBytes)
        await gate.resume()
        let restoredBackup = try await restore.value

        XCTAssertEqual(restoredBackup.id, confirmed.id)
        XCTAssertEqual(try Data(contentsOf: backup), expectedBytes)
        XCTAssertFalse(FileManager.default.fileExists(atPath: wal.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: shm.path))
        XCTAssertEqual(try Data(contentsOf: lookalike), Data("keep".utf8))
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(
                at: backups,
                includingPropertiesForKeys: nil
            ).map(\.lastPathComponent),
            [backup.lastPathComponent]
        )
        let restoredLedger = try SQLiteLedger(databaseURL: setup.database, backupDirectory: backups)
        try await restoredLedger.migrate()
        try await restoredLedger.integrityCheck()
        let restoredRows = try await restoredLedger.usageRows(in: nil, calendar: calendar)
        XCTAssertEqual(restoredRows.map(\.quantity), [41])
        try await restoredLedger.shutdown()
    }

    func testShutdownFailureDoesNotReplaceDatabaseOrModifyBackup() async throws {
        let setup = try await makePopulatedLedger(quantity: 43)
        defer { try? FileManager.default.removeItem(at: setup.directory) }
        try await setup.ledger.shutdown()
        let backups = setup.directory.appending(path: "Backups", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: backups, withIntermediateDirectories: true)
        let backup = backups.appending(path: "ledger-v1-100.sqlite")
        let databaseBefore = try Data(contentsOf: setup.database)
        try databaseBefore.write(to: backup)
        let backupBefore = try Data(contentsOf: backup)
        let service = DatabaseRecoveryService(databaseURL: setup.database, backupDirectory: backups)
        let available = try await service.availableBackups()
        let confirmed = try XCTUnwrap(available.first)

        do {
            _ = try await service.restore(confirmed) { throw RecoveryTestError.shutdownFailed }
            XCTFail("expected shutdown failure")
        } catch let error as RecoveryTestError {
            XCTAssertEqual(error, .shutdownFailed)
        }

        XCTAssertEqual(try Data(contentsOf: setup.database), databaseBefore)
        XCTAssertEqual(try Data(contentsOf: backup), backupBefore)
    }

    func testInvalidLatestBackupIsNotOfferedAndPreservesOriginalAndLookalike() async throws {
        let setup = try await makePopulatedLedger(quantity: 47)
        defer { try? FileManager.default.removeItem(at: setup.directory) }
        try await setup.ledger.shutdown()
        let original = try Data(contentsOf: setup.database)
        let backups = setup.directory.appending(path: "Backups", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: backups, withIntermediateDirectories: true)
        let invalidBackup = backups.appending(path: "ledger-v1-999.sqlite")
        let invalidBytes = Data(repeating: 0xA5, count: 256)
        try invalidBytes.write(to: invalidBackup)
        let service = DatabaseRecoveryService(databaseURL: setup.database, backupDirectory: backups)
        let available = try await service.availableBackups()
        XCTAssertEqual(available, [])

        XCTAssertEqual(try Data(contentsOf: setup.database), original)
        XCTAssertEqual(try Data(contentsOf: invalidBackup), invalidBytes)
        let reopened = try SQLiteLedger(databaseURL: setup.database, backupDirectory: backups)
        try await reopened.migrate()
        try await reopened.integrityCheck()
        let reopenedRows = try await reopened.usageRows(in: nil, calendar: calendar)
        XCTAssertEqual(reopenedRows.map(\.quantity), [47])
        try await reopened.shutdown()
    }

    func testConcurrentRestoreIsRejectedBeforeASecondBarrierCanStart() async throws {
        let setup = try await makePopulatedLedger(quantity: 51)
        defer { try? FileManager.default.removeItem(at: setup.directory) }
        try await setup.ledger.shutdown()
        let backups = setup.directory.appending(path: "Backups", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: backups, withIntermediateDirectories: true)
        try Data(contentsOf: setup.database).write(
            to: backups.appending(path: "ledger-v1-100.sqlite")
        )
        let service = DatabaseRecoveryService(databaseURL: setup.database, backupDirectory: backups)
        let available = try await service.availableBackups()
        let confirmed = try XCTUnwrap(available.first)
        let gate = RecoveryGate()
        let first = Task {
            try await service.restore(confirmed) {
                await gate.enter()
                await gate.wait()
            }
        }
        await gate.waitUntilEntered()

        await assertRecoveryError(.restoreInProgress) {
            _ = try await service.restore(confirmed) {
                XCTFail("concurrent restore reached a second shutdown barrier")
            }
        }

        await gate.resume()
        _ = try await first.value
    }

    func testConfirmedBackupReplacementIsRejectedWithoutChangingDatabase() async throws {
        let setup = try await makePopulatedLedger(quantity: 53)
        defer { try? FileManager.default.removeItem(at: setup.directory) }
        try await setup.ledger.shutdown()
        let original = try Data(contentsOf: setup.database)
        let backups = setup.directory.appending(path: "Backups", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: backups, withIntermediateDirectories: true)
        let backup = backups.appending(path: "ledger-v1-100.sqlite")
        try original.write(to: backup)
        let service = DatabaseRecoveryService(databaseURL: setup.database, backupDirectory: backups)
        let available = try await service.availableBackups()
        let confirmed = try XCTUnwrap(available.first)
        let replacement = backup.appendingPathExtension("replacement")
        try Data(repeating: 0x5A, count: original.count).write(to: replacement)
        _ = try FileManager.default.replaceItemAt(backup, withItemAt: replacement)

        await assertRecoveryError(.backupChanged) {
            _ = try await service.restore(confirmed) {}
        }

        XCTAssertEqual(try Data(contentsOf: setup.database), original)
    }

    func testSymlinkSidecarIsRejectedWithoutFollowingOrRemovingIt() async throws {
        let setup = try await makePopulatedLedger(quantity: 59)
        defer { try? FileManager.default.removeItem(at: setup.directory) }
        try await setup.ledger.shutdown()
        let original = try Data(contentsOf: setup.database)
        let backups = setup.directory.appending(path: "Backups", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: backups, withIntermediateDirectories: true)
        try original.write(to: backups.appending(path: "ledger-v1-100.sqlite"))
        let outside = setup.directory.appending(path: "outside-sentinel")
        let sentinel = Data("outside".utf8)
        try sentinel.write(to: outside)
        let wal = setup.directory.appending(path: "ledger.sqlite-wal")
        try? FileManager.default.removeItem(at: wal)
        try FileManager.default.createSymbolicLink(at: wal, withDestinationURL: outside)
        let lookalike = setup.directory.appending(path: "ledger.sqlite-wal.keep")
        try Data("keep".utf8).write(to: lookalike)
        let service = DatabaseRecoveryService(databaseURL: setup.database, backupDirectory: backups)
        let available = try await service.availableBackups()
        let confirmed = try XCTUnwrap(available.first)

        await assertRecoveryError(.unsafeSidecar) {
            _ = try await service.restore(confirmed) {}
        }

        XCTAssertEqual(try Data(contentsOf: setup.database), original)
        XCTAssertEqual(try Data(contentsOf: outside), sentinel)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: wal.path), outside.path)
        XCTAssertEqual(try Data(contentsOf: lookalike), Data("keep".utf8))
    }

    func testCancellationAfterReplacementRollsBackBeforeReturning() async throws {
        let setup = try await makePopulatedLedger(quantity: 61)
        defer { try? FileManager.default.removeItem(at: setup.directory) }
        try await setup.ledger.shutdown()
        let original = try Data(contentsOf: setup.database)
        let backups = setup.directory.appending(path: "Backups", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: backups, withIntermediateDirectories: true)
        try original.write(to: backups.appending(path: "ledger-v1-100.sqlite"))
        let gate = RecoveryGate()
        let service = DatabaseRecoveryService(
            databaseURL: setup.database,
            backupDirectory: backups,
            stageHandler: { stage in
                guard stage == .afterReplacement else { return }
                await gate.enter()
                await gate.wait()
            }
        )
        let available = try await service.availableBackups()
        let confirmed = try XCTUnwrap(available.first)
        let restore = Task { try await service.restore(confirmed) {} }
        await gate.waitUntilEntered()

        restore.cancel()
        await gate.resume()
        await XCTAssertThrowsErrorAsync { _ = try await restore.value }

        XCTAssertEqual(try Data(contentsOf: setup.database), original)
        XCTAssertEqual(try Data(contentsOf: backups.appending(path: "ledger-v1-100.sqlite")), original)
    }

    func testCancellationAtBarrierAndBeforeReplacementLeavesDatabaseAndSidecarsUntouched() async throws {
        for cancellationPoint in [DatabaseRecoveryStage?.none, .some(.beforeReplacement)] {
            let setup = try await makePopulatedLedger(quantity: 67)
            defer { try? FileManager.default.removeItem(at: setup.directory) }
            try await setup.ledger.shutdown()
            let original = try Data(contentsOf: setup.database)
            let backups = setup.directory.appending(path: "Backups", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: backups, withIntermediateDirectories: true)
            let backup = backups.appending(path: "ledger-v1-100.sqlite")
            try original.write(to: backup)
            let sidecar = setup.directory.appending(path: "ledger.sqlite-wal")
            try? FileManager.default.removeItem(at: sidecar)
            let sidecarBytes = Data("sidecar".utf8)
            try sidecarBytes.write(to: sidecar)
            let gate = RecoveryGate()
            let service = DatabaseRecoveryService(
                databaseURL: setup.database,
                backupDirectory: backups,
                stageHandler: { stage in
                    guard cancellationPoint == stage else { return }
                    await gate.enter()
                    await gate.wait()
                }
            )
            let available = try await service.availableBackups()
            let confirmed = try XCTUnwrap(available.first)
            let restore = Task {
                try await service.restore(confirmed) {
                    guard cancellationPoint == nil else { return }
                    await gate.enter()
                    await gate.wait()
                    try Task.checkCancellation()
                }
            }
            await gate.waitUntilEntered()

            restore.cancel()
            await gate.resume()
            await XCTAssertThrowsErrorAsync { _ = try await restore.value }

            XCTAssertEqual(try Data(contentsOf: setup.database), original)
            XCTAssertEqual(try Data(contentsOf: backup), original)
            XCTAssertEqual(try Data(contentsOf: sidecar), sidecarBytes)
        }
    }

    func testPartialRestoreCopyFailureCleansStagingWithoutMutatingDatabaseOrBackup() async throws {
        let setup = try await makePopulatedLedger(quantity: 69)
        defer { try? FileManager.default.removeItem(at: setup.directory) }
        try await setup.ledger.shutdown()
        let original = try Data(contentsOf: setup.database)
        let backups = setup.directory.appending(path: "Backups", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: backups, withIntermediateDirectories: true)
        let backup = backups.appending(path: "ledger-v1-100.sqlite")
        let backupBytes = original
        try backupBytes.write(to: backup)
        let sidecar = setup.directory.appending(path: "ledger.sqlite-wal")
        let sidecarBytes = Data("sidecar".utf8)
        try sidecarBytes.write(to: sidecar)
        let service = DatabaseRecoveryService(
            databaseURL: setup.database,
            backupDirectory: backups,
            stageHandler: { _ in },
            fileOperationHandler: { operation in
                if operation == .restoreCopyChunk { throw RecoveryTestError.rollbackFailed }
            }
        )
        let available = try await service.availableBackups()
        let confirmed = try XCTUnwrap(available.first)

        await assertRecoveryError(.restoreFailed) {
            _ = try await service.restore(confirmed) {}
        }

        XCTAssertEqual(try Data(contentsOf: setup.database), original)
        XCTAssertEqual(try Data(contentsOf: backup), backupBytes)
        XCTAssertEqual(try Data(contentsOf: sidecar), sidecarBytes)
        let names = try FileManager.default.contentsOfDirectory(atPath: setup.directory.path)
        XCTAssertFalse(names.contains { $0.hasPrefix(".tokenboard-restore-") })
        XCTAssertFalse(names.contains { $0.hasPrefix(".tokenboard-pre-restore-") })
    }

    func testSymlinkDatabaseAndBackupDirectoryAreRejectedWithoutFollowing() async throws {
        let setup = try await makePopulatedLedger(quantity: 71)
        defer { try? FileManager.default.removeItem(at: setup.directory) }
        try await setup.ledger.shutdown()
        let original = try Data(contentsOf: setup.database)
        let backups = setup.directory.appending(path: "Backups", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: backups, withIntermediateDirectories: true)
        try original.write(to: backups.appending(path: "ledger-v1-100.sqlite"))
        let service = DatabaseRecoveryService(databaseURL: setup.database, backupDirectory: backups)
        let available = try await service.availableBackups()
        let confirmed = try XCTUnwrap(available.first)
        let outsideDatabase = setup.directory.appending(path: "outside-database")
        try FileManager.default.moveItem(at: setup.database, to: outsideDatabase)
        try FileManager.default.createSymbolicLink(
            at: setup.database,
            withDestinationURL: outsideDatabase
        )

        await assertRecoveryError(.unsafeDatabase) {
            _ = try await service.restore(confirmed) {}
        }
        XCTAssertEqual(try Data(contentsOf: outsideDatabase), original)

        try FileManager.default.removeItem(at: backups)
        let outsideBackups = setup.directory.appending(path: "OutsideBackups")
        try FileManager.default.createDirectory(
            at: outsideBackups,
            withIntermediateDirectories: false
        )
        try FileManager.default.createSymbolicLink(at: backups, withDestinationURL: outsideBackups)
        let symlinked = DatabaseRecoveryService(databaseURL: setup.database, backupDirectory: backups)
        await assertRecoveryError(.invalidDatabaseLocation) {
            _ = try await symlinked.availableBackups()
        }

        let escapedRoot = setup.directory.appending(path: "escaped-root", directoryHint: .isDirectory)
        let escapedSupport = escapedRoot.appending(path: "Support", directoryHint: .isDirectory)
        let escapedBackups = escapedSupport.appending(path: "Backups", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: escapedBackups, withIntermediateDirectories: true)
        let escapedDatabase = escapedSupport.appending(path: "ledger.sqlite")
        try original.write(to: escapedDatabase)
        try original.write(to: escapedBackups.appending(path: "ledger-v1-100.sqlite"))
        let ancestorLink = setup.directory.appending(path: "ancestor-link", directoryHint: .isDirectory)
        try FileManager.default.createSymbolicLink(
            at: ancestorLink,
            withDestinationURL: escapedRoot
        )
        let escaped = DatabaseRecoveryService(
            databaseURL: ancestorLink.appending(path: "Support/ledger.sqlite"),
            backupDirectory: ancestorLink.appending(path: "Support/Backups", directoryHint: .isDirectory)
        )

        await assertRecoveryError(.invalidDatabaseLocation) {
            _ = try await escaped.availableBackups()
        }
        XCTAssertEqual(try Data(contentsOf: escapedDatabase), original)
    }

    func testRollbackFailurePreservesImmutableSnapshotAndConfirmedBackup() async throws {
        let setup = try await makePopulatedLedger(quantity: 73)
        defer { try? FileManager.default.removeItem(at: setup.directory) }
        try await setup.ledger.shutdown()
        let original = try Data(contentsOf: setup.database)
        let backups = setup.directory.appending(path: "Backups", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: backups, withIntermediateDirectories: true)
        let backup = backups.appending(path: "ledger-v1-100.sqlite")
        let validBackup = try await databaseBytes(quantity: 83)
        try validBackup.write(to: backup)
        let service = DatabaseRecoveryService(
            databaseURL: setup.database,
            backupDirectory: backups,
            stageHandler: { stage in
                if stage == .afterReplacement { throw RecoveryTestError.shutdownFailed }
                if stage == .beforeRollback { throw RecoveryTestError.rollbackFailed }
            }
        )
        let available = try await service.availableBackups()
        let confirmed = try XCTUnwrap(available.first)

        await assertRecoveryError(.rollbackFailed) {
            _ = try await service.restore(confirmed) {}
        }

        let artifacts = try FileManager.default.contentsOfDirectory(
            atPath: setup.directory.path
        ).filter { $0.hasPrefix(".tokenboard-pre-restore-") }
        XCTAssertEqual(artifacts.count, 1)
        XCTAssertEqual(
            try Data(contentsOf: setup.directory.appending(path: artifacts[0])),
            original
        )
        XCTAssertEqual(try Data(contentsOf: backup), validBackup)
    }

    func testStagedNameSubstitutionCannotRedirectRetainedRestoreDescriptor() async throws {
        let setup = try await makePopulatedLedger(quantity: 87)
        defer { try? FileManager.default.removeItem(at: setup.directory) }
        try await setup.ledger.shutdown()
        let original = try Data(contentsOf: setup.database)
        let backups = setup.directory.appending(path: "Backups", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: backups, withIntermediateDirectories: true)
        let backup = backups.appending(path: "ledger-v1-100.sqlite")
        try await databaseBytes(quantity: 89).write(to: backup)
        let service = DatabaseRecoveryService(
            databaseURL: setup.database,
            backupDirectory: backups,
            stageHandler: { stage in
                guard stage == .beforeReplacement else { return }
                let names = try FileManager.default.contentsOfDirectory(atPath: setup.directory.path)
                let staged = try XCTUnwrap(names.first { $0.hasPrefix(".tokenboard-restore-") })
                let stagedURL = setup.directory.appending(path: staged)
                try FileManager.default.moveItem(
                    at: stagedURL,
                    to: setup.directory.appending(path: ".retained-stage")
                )
                try Data("attacker".utf8).write(to: stagedURL)
            }
        )
        let available = try await service.availableBackups()
        let confirmed = try XCTUnwrap(available.first)

        await assertRecoveryError(.restoreFailed) {
            _ = try await service.restore(confirmed) {}
        }

        XCTAssertEqual(try Data(contentsOf: setup.database), original)
        XCTAssertEqual(
            try Data(contentsOf: setup.directory.appending(path: ".retained-stage")) == Data("attacker".utf8),
            false
        )
    }

    func testRollbackSnapshotNameSubstitutionCannotRedirectRetainedSnapshot() async throws {
        let setup = try await makePopulatedLedger(quantity: 91)
        defer { try? FileManager.default.removeItem(at: setup.directory) }
        try await setup.ledger.shutdown()
        let original = try Data(contentsOf: setup.database)
        let backups = setup.directory.appending(path: "Backups", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: backups, withIntermediateDirectories: true)
        let backup = backups.appending(path: "ledger-v1-100.sqlite")
        let replacement = try await databaseBytes(quantity: 93)
        try replacement.write(to: backup)
        let service = DatabaseRecoveryService(
            databaseURL: setup.database,
            backupDirectory: backups,
            stageHandler: { stage in
                if stage == .afterReplacement { throw RecoveryTestError.shutdownFailed }
                guard stage == .beforeRollback else { return }
                let names = try FileManager.default.contentsOfDirectory(atPath: setup.directory.path)
                let snapshot = try XCTUnwrap(names.first { $0.hasPrefix(".tokenboard-pre-restore-") })
                let snapshotURL = setup.directory.appending(path: snapshot)
                try FileManager.default.moveItem(
                    at: snapshotURL,
                    to: setup.directory.appending(path: ".retained-snapshot")
                )
                try replacement.write(to: snapshotURL)
            }
        )
        let available = try await service.availableBackups()
        let confirmed = try XCTUnwrap(available.first)

        await assertRecoveryError(.rollbackFailed) {
            _ = try await service.restore(confirmed) {}
        }

        XCTAssertEqual(
            try Data(contentsOf: setup.directory.appending(path: ".retained-snapshot")),
            original
        )
        guard try await databaseQuantities(at: setup.database, backups: backups) == [93] else {
            throw RecoveryInvariantTestError.installedBackupContentsInvalid
        }
    }

    func testRollbackRejectsInPlaceSnapshotMutationAgainstPreAwaitIdentity() async throws {
        let setup = try await makePopulatedLedger(quantity: 94)
        defer { try? FileManager.default.removeItem(at: setup.directory) }
        try await setup.ledger.shutdown()
        let backups = setup.directory.appending(path: "Backups", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: backups, withIntermediateDirectories: true)
        let replacement = try await databaseBytes(quantity: 96)
        try replacement.write(to: backups.appending(path: "ledger-v1-100.sqlite"))
        let service = DatabaseRecoveryService(
            databaseURL: setup.database,
            backupDirectory: backups,
            stageHandler: { stage in
                if stage == .afterReplacement { throw RecoveryTestError.shutdownFailed }
                guard stage == .beforeRollback else { return }
                let names = try FileManager.default.contentsOfDirectory(atPath: setup.directory.path)
                let snapshot = try XCTUnwrap(names.first { $0.hasPrefix(".tokenboard-pre-restore-") })
                let snapshotURL = setup.directory.appending(path: snapshot)
                try FileManager.default.setAttributes(
                    [.posixPermissions: NSNumber(value: S_IRUSR | S_IWUSR)],
                    ofItemAtPath: snapshotURL.path
                )
                let handle = try FileHandle(forWritingTo: snapshotURL)
                try handle.truncate(atOffset: 0)
                try handle.write(contentsOf: Data("mutated-snapshot".utf8))
                try handle.close()
            }
        )
        let available = try await service.availableBackups()
        let confirmed = try XCTUnwrap(available.first)

        await assertRecoveryError(.rollbackFailed) {
            _ = try await service.restore(confirmed) {}
        }

        guard try await databaseQuantities(at: setup.database, backups: backups) == [96] else {
            throw RecoveryInvariantTestError.installedBackupContentsInvalid
        }
    }

    func testInstalledLeafSwapAfterReplacementRollsBackWithoutTouchingOutsideFile() async throws {
        let setup = try await makePopulatedLedger(quantity: 95)
        defer { try? FileManager.default.removeItem(at: setup.directory) }
        try await setup.ledger.shutdown()
        let original = try Data(contentsOf: setup.database)
        let backups = setup.directory.appending(path: "Backups", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: backups, withIntermediateDirectories: true)
        try await databaseBytes(quantity: 97).write(
            to: backups.appending(path: "ledger-v1-100.sqlite")
        )
        let outside = setup.directory.appending(path: "outside-sentinel")
        let sentinel = Data("outside-must-not-change".utf8)
        try sentinel.write(to: outside)
        let service = DatabaseRecoveryService(
            databaseURL: setup.database,
            backupDirectory: backups,
            stageHandler: { stage in
                guard stage == .afterReplacement else { return }
                try FileManager.default.moveItem(
                    at: setup.database,
                    to: setup.directory.appending(path: ".displaced-installed")
                )
                try FileManager.default.createSymbolicLink(
                    at: setup.database,
                    withDestinationURL: outside
                )
            }
        )
        let available = try await service.availableBackups()
        let confirmed = try XCTUnwrap(available.first)

        await assertRecoveryError(.rollbackCompleted) {
            _ = try await service.restore(confirmed) {}
        }

        XCTAssertEqual(try Data(contentsOf: outside), sentinel)
        XCTAssertEqual(try Data(contentsOf: setup.database), original)
    }

    func testParentDirectorySwapAfterReplacementRollsBackThroughRetainedDirectory() async throws {
        let setup = try await makePopulatedLedger(quantity: 99)
        let moved = setup.directory.deletingLastPathComponent()
            .appending(path: setup.directory.lastPathComponent + "-moved")
        defer {
            try? FileManager.default.removeItem(at: setup.directory)
            try? FileManager.default.removeItem(at: moved)
        }
        try await setup.ledger.shutdown()
        let original = try Data(contentsOf: setup.database)
        let backups = setup.directory.appending(path: "Backups", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: backups, withIntermediateDirectories: true)
        try await databaseBytes(quantity: 101).write(
            to: backups.appending(path: "ledger-v1-100.sqlite")
        )
        let outside = Data("replacement-directory-sentinel".utf8)
        let service = DatabaseRecoveryService(
            databaseURL: setup.database,
            backupDirectory: backups,
            stageHandler: { stage in
                guard stage == .afterReplacement else { return }
                try FileManager.default.moveItem(at: setup.directory, to: moved)
                try FileManager.default.createDirectory(at: setup.directory, withIntermediateDirectories: false)
                try outside.write(to: setup.database)
            }
        )
        let available = try await service.availableBackups()
        let confirmed = try XCTUnwrap(available.first)

        await assertRecoveryError(.rollbackCompleted) {
            _ = try await service.restore(confirmed) {}
        }

        XCTAssertEqual(try Data(contentsOf: setup.database), outside)
        XCTAssertEqual(try Data(contentsOf: moved.appending(path: "ledger.sqlite")), original)
    }

    func testDurabilityFaultsBeforeCommitNeverDiscardRollbackSnapshot() async throws {
        let operations: [DatabaseRecoveryFileOperation] = [
            .syncStagedRestore,
            .syncRollbackSnapshot,
            .removeSidecar,
            .syncBeforeReplacement,
            .syncAfterReplacement
        ]
        for operation in operations {
            let setup = try await makePopulatedLedger(quantity: 103)
            defer { try? FileManager.default.removeItem(at: setup.directory) }
            try await setup.ledger.shutdown()
            let original = try Data(contentsOf: setup.database)
            let backups = setup.directory.appending(path: "Backups", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: backups, withIntermediateDirectories: true)
            let backup = backups.appending(path: "ledger-v1-100.sqlite")
            let replacement = try await databaseBytes(quantity: 105)
            try replacement.write(to: backup)
            try Data("checkpointed-sidecar".utf8).write(
                to: setup.directory.appending(path: "ledger.sqlite-wal")
            )
            let service = DatabaseRecoveryService(
                databaseURL: setup.database,
                backupDirectory: backups,
                stageHandler: { _ in },
                fileOperationHandler: { observed in
                    if observed == operation { throw RecoveryTestError.shutdownFailed }
                }
            )
            let available = try await service.availableBackups()
            let confirmed = try XCTUnwrap(available.first)

            await XCTAssertThrowsErrorAsync {
                _ = try await service.restore(confirmed) {}
            }

            XCTAssertEqual(try Data(contentsOf: setup.database), original, "fault: \(operation)")
            XCTAssertEqual(try Data(contentsOf: backup), replacement)
        }
    }

    func testSuccessfulRestoreCleanupFaultIsDistinctAndPreservesSnapshotArtifact() async throws {
        for operation in [DatabaseRecoveryFileOperation.syncCleanup] {
            let setup = try await makePopulatedLedger(quantity: 107)
            defer { try? FileManager.default.removeItem(at: setup.directory) }
            try await setup.ledger.shutdown()
            let original = try Data(contentsOf: setup.database)
            let backups = setup.directory.appending(path: "Backups", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: backups, withIntermediateDirectories: true)
            let backup = backups.appending(path: "ledger-v1-100.sqlite")
            try await databaseBytes(quantity: 109).write(to: backup)
            let service = DatabaseRecoveryService(
                databaseURL: setup.database,
                backupDirectory: backups,
                stageHandler: { _ in },
                fileOperationHandler: { observed in
                    if observed == operation { throw RecoveryTestError.shutdownFailed }
                }
            )
            let available = try await service.availableBackups()
            let confirmed = try XCTUnwrap(available.first)

            await assertRecoveryError(.cleanupPending) {
                _ = try await service.restore(confirmed) {}
            }

            let restored = try SQLiteLedger(databaseURL: setup.database, backupDirectory: backups)
            try await restored.migrate()
            let restoredRows = try await restored.usageRows(in: nil, calendar: calendar)
            XCTAssertEqual(restoredRows.map(\.quantity), [109])
            try await restored.shutdown()
            let artifacts = try FileManager.default.contentsOfDirectory(atPath: setup.directory.path)
                .filter {
                    $0.hasPrefix(".tokenboard-pre-restore-")
                        || $0.hasPrefix(".tokenboard-cleanup-pending-")
                }
            XCTAssertFalse(artifacts.isEmpty, "fault: \(operation)")
            XCTAssertTrue(artifacts.contains {
                (try? Data(contentsOf: setup.directory.appending(path: $0))) == original
            })
        }
    }

    func testRollbackCleanupFaultIsDistinctAndPreservesOriginalSnapshot() async throws {
        let setup = try await makePopulatedLedger(quantity: 111)
        defer { try? FileManager.default.removeItem(at: setup.directory) }
        try await setup.ledger.shutdown()
        let original = try Data(contentsOf: setup.database)
        let backups = setup.directory.appending(path: "Backups", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: backups, withIntermediateDirectories: true)
        try await databaseBytes(quantity: 113).write(
            to: backups.appending(path: "ledger-v1-100.sqlite")
        )
        let service = DatabaseRecoveryService(
            databaseURL: setup.database,
            backupDirectory: backups,
            stageHandler: { stage in
                if stage == .afterReplacement { throw RecoveryTestError.shutdownFailed }
            },
            fileOperationHandler: { operation in
                if operation == .syncCleanup { throw RecoveryTestError.rollbackFailed }
            }
        )
        let available = try await service.availableBackups()
        let confirmed = try XCTUnwrap(available.first)

        await assertRecoveryError(.restoreFailedCleanupPending) {
            _ = try await service.restore(confirmed) {}
        }

        XCTAssertEqual(try Data(contentsOf: setup.database), original)
        let artifacts = try FileManager.default.contentsOfDirectory(atPath: setup.directory.path)
            .filter { $0.hasPrefix(".tokenboard-pre-restore-") }
        XCTAssertEqual(artifacts.count, 1)
        XCTAssertEqual(try Data(contentsOf: setup.directory.appending(path: artifacts[0])), original)
    }

    func testMatchingFIFOsFailPromptlyWithoutMutation() async throws {
        let setup = try await makePopulatedLedger(quantity: 115)
        defer { try? FileManager.default.removeItem(at: setup.directory) }
        try await setup.ledger.shutdown()
        let original = try Data(contentsOf: setup.database)
        let backups = setup.directory.appending(path: "Backups", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: backups, withIntermediateDirectories: true)
        let fifoBackup = backups.appending(path: "ledger-v1-100.sqlite")
        XCTAssertEqual(Darwin.mkfifo(fifoBackup.path, S_IRUSR | S_IWUSR), 0)
        let service = DatabaseRecoveryService(databaseURL: setup.database, backupDirectory: backups)
        let started = Date()
        let fifoBackups = try await service.availableBackups()
        XCTAssertTrue(fifoBackups.isEmpty)
        XCTAssertLessThan(Date().timeIntervalSince(started), 1)
        XCTAssertEqual(try Data(contentsOf: setup.database), original)

        try FileManager.default.removeItem(at: fifoBackup)
        try original.write(to: fifoBackup)
        let available = try await service.availableBackups()
        let confirmed = try XCTUnwrap(available.first)
        try FileManager.default.removeItem(at: setup.database)
        XCTAssertEqual(Darwin.mkfifo(setup.database.path, S_IRUSR | S_IWUSR), 0)
        let databaseStarted = Date()
        await assertRecoveryError(.unsafeDatabase) {
            _ = try await service.restore(confirmed) {}
        }
        XCTAssertLessThan(Date().timeIntervalSince(databaseStarted), 1)

        try FileManager.default.removeItem(at: setup.database)
        try original.write(to: setup.database)
        let fifoSidecar = setup.directory.appending(path: "ledger.sqlite-wal")
        try? FileManager.default.removeItem(at: fifoSidecar)
        XCTAssertEqual(Darwin.mkfifo(fifoSidecar.path, S_IRUSR | S_IWUSR), 0)
        let sidecarStarted = Date()
        await assertRecoveryError(.unsafeSidecar) {
            _ = try await service.restore(confirmed) {}
        }
        XCTAssertLessThan(Date().timeIntervalSince(sidecarStarted), 1)
        XCTAssertEqual(try Data(contentsOf: setup.database), original)
    }

    func testCompletedRestoreReturnsWithOriginalSnapshotStillNamedAndVerified() async throws {
        let setup = try await makePopulatedLedger(quantity: 117)
        defer { try? FileManager.default.removeItem(at: setup.directory) }
        try await setup.ledger.shutdown()
        let original = try Data(contentsOf: setup.database)
        let backups = setup.directory.appending(path: "Backups", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: backups, withIntermediateDirectories: true)
        try await databaseBytes(quantity: 119).write(
            to: backups.appending(path: "ledger-v1-100.sqlite")
        )
        let service = DatabaseRecoveryService(databaseURL: setup.database, backupDirectory: backups)
        let available = try await service.availableBackups()
        let confirmed = try XCTUnwrap(available.first)

        _ = try await service.restore(confirmed) {}

        let artifacts = try FileManager.default.contentsOfDirectory(atPath: setup.directory.path)
            .filter { $0.hasPrefix(".tokenboard-pre-restore-") }
        guard artifacts.count == 1 else {
            throw RecoveryInvariantTestError.missingNamedSnapshot
        }
        let artifact = setup.directory.appending(path: artifacts[0])
        var information = stat()
        guard lstat(artifact.path, &information) == 0,
              information.st_mode & S_IFMT == S_IFREG,
              information.st_nlink == 1,
              information.st_mode & S_IWUSR == 0,
              try Data(contentsOf: artifact) == original else {
            throw RecoveryInvariantTestError.invalidNamedSnapshot
        }
    }

    func testFinalInstalledIdentityDetectsSameInodeSameSizeMutationWithRestoredMtime() async throws {
        let setup = try await makePopulatedLedger(quantity: 121)
        defer { try? FileManager.default.removeItem(at: setup.directory) }
        try await setup.ledger.shutdown()
        let original = try Data(contentsOf: setup.database)
        let backups = setup.directory.appending(path: "Backups", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: backups, withIntermediateDirectories: true)
        try await databaseBytes(quantity: 123).write(
            to: backups.appending(path: "ledger-v1-100.sqlite")
        )
        let service = DatabaseRecoveryService(
            databaseURL: setup.database,
            backupDirectory: backups,
            stageHandler: { stage in
                guard stage == .afterValidation else { return }
                try Self.mutateLastBytePreservingStat(at: setup.database)
            }
        )
        let available = try await service.availableBackups()
        let confirmed = try XCTUnwrap(available.first)

        do {
            _ = try await service.restore(confirmed) {}
            throw RecoveryInvariantTestError.mutatedInstalledDatabaseAccepted
        } catch RecoveryInvariantTestError.mutatedInstalledDatabaseAccepted {
            throw RecoveryInvariantTestError.mutatedInstalledDatabaseAccepted
        } catch {
        }

        XCTAssertEqual(try Data(contentsOf: setup.database), original)
    }

    func testFinalSnapshotIdentityDetectsSameInodeSameSizeMutationWithRestoredMtime() async throws {
        let setup = try await makePopulatedLedger(quantity: 118)
        defer { try? FileManager.default.removeItem(at: setup.directory) }
        try await setup.ledger.shutdown()
        let backups = setup.directory.appending(path: "Backups", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: backups, withIntermediateDirectories: true)
        let backup = backups.appending(path: "ledger-v2-100.sqlite")
        let replacement = try await databaseBytes(quantity: 120)
        try replacement.write(to: backup)
        let service = DatabaseRecoveryService(
            databaseURL: setup.database,
            backupDirectory: backups,
            stageHandler: { stage in
                guard stage == .afterValidation else { return }
                let names = try FileManager.default.contentsOfDirectory(atPath: setup.directory.path)
                guard let name = names.first(where: { $0.hasPrefix(".tokenboard-pre-restore-") }) else {
                    throw RecoveryInvariantTestError.missingNamedSnapshot
                }
                let snapshot = setup.directory.appending(path: name)
                try FileManager.default.setAttributes(
                    [.posixPermissions: NSNumber(value: S_IRUSR | S_IWUSR)],
                    ofItemAtPath: snapshot.path
                )
                try Self.mutateLastBytePreservingStat(at: snapshot)
            }
        )
        let available = try await service.availableBackups()
        let confirmed = try XCTUnwrap(available.first)

        do {
            _ = try await service.restore(confirmed) {}
            throw RecoveryInvariantTestError.mutatedSnapshotAccepted
        } catch let error as DatabaseRecoveryError {
            guard error == .preservationFailed else { throw error }
        }

        guard try await databaseQuantities(at: setup.database, backups: backups) == [120] else {
            throw RecoveryInvariantTestError.installedBackupContentsInvalid
        }
        XCTAssertEqual(try Data(contentsOf: backup), replacement)
    }

    func testCleanupSyncFailureKeepsTheOriginalNamedSnapshotInsteadOfRecreatingIt() async throws {
        let setup = try await makePopulatedLedger(quantity: 125)
        defer { try? FileManager.default.removeItem(at: setup.directory) }
        try await setup.ledger.shutdown()
        let original = try Data(contentsOf: setup.database)
        let backups = setup.directory.appending(path: "Backups", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: backups, withIntermediateDirectories: true)
        try await databaseBytes(quantity: 127).write(
            to: backups.appending(path: "ledger-v1-100.sqlite")
        )
        let service = DatabaseRecoveryService(
            databaseURL: setup.database,
            backupDirectory: backups,
            stageHandler: { _ in },
            fileOperationHandler: { operation in
                if operation == .syncCleanup { throw RecoveryTestError.shutdownFailed }
            }
        )
        let available = try await service.availableBackups()
        let confirmed = try XCTUnwrap(available.first)

        await XCTAssertThrowsErrorAsync { _ = try await service.restore(confirmed) {} }

        let artifacts = try FileManager.default.contentsOfDirectory(atPath: setup.directory.path)
            .filter { $0.hasPrefix(".tokenboard-pre-restore-") }
        guard artifacts.count == 1,
              try Data(contentsOf: setup.directory.appending(path: artifacts[0])) == original else {
            throw RecoveryInvariantTestError.missingNamedSnapshot
        }
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: setup.directory.path)
            .contains { $0.hasPrefix(".tokenboard-cleanup-pending-") })
    }

    func testRecoveryImageAtExactConfiguredLimitRestoresSuccessfully() async throws {
        let setup = try await makePopulatedLedger(quantity: 121)
        defer { try? FileManager.default.removeItem(at: setup.directory) }
        try await setup.ledger.shutdown()
        let backupBytes = try Data(contentsOf: setup.database)
        let backups = setup.directory.appending(path: "Backups", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: backups, withIntermediateDirectories: true)
        let backup = backups.appending(path: "ledger-v2-100.sqlite")
        try backupBytes.write(to: backup)
        let service = DatabaseRecoveryService(
            databaseURL: setup.database,
            backupDirectory: backups,
            stageHandler: { _ in },
            maximumRecoveryImageBytes: backupBytes.count
        )
        let available = try await service.availableBackups()
        let confirmed = try XCTUnwrap(available.first)

        _ = try await service.restore(confirmed) {}

        let restored = try SQLiteLedger(databaseURL: setup.database, backupDirectory: backups)
        try await restored.migrate()
        let quantities = try await restored.usageRows(in: nil, calendar: calendar).map(\.quantity)
        try await restored.shutdown()
        guard quantities == [121] else { throw RecoveryInvariantTestError.boundaryRestoreFailed }
        XCTAssertEqual(try Data(contentsOf: backup), backupBytes)
    }

    func testBackupGrowthDuringRestoreIsRejectedWithoutCopyingPastConfirmedSize() async throws {
        let setup = try await makePopulatedLedger(quantity: 122)
        defer { try? FileManager.default.removeItem(at: setup.directory) }
        try await setup.ledger.shutdown()
        let original = try Data(contentsOf: setup.database)
        let backups = setup.directory.appending(path: "Backups", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: backups, withIntermediateDirectories: true)
        let backup = backups.appending(path: "ledger-v2-100.sqlite")
        try original.write(to: backup)
        let recorder = RecoveryOperationRecorder()
        let grower = RecoveryBackupGrower()
        let service = DatabaseRecoveryService(
            databaseURL: setup.database,
            backupDirectory: backups,
            stageHandler: { _ in },
            fileOperationHandler: { operation in
                guard operation == .restoreCopyChunk else { return }
                recorder.recordChunk()
                try grower.appendOnce(
                    to: backup,
                    bytes: 3 * 64 * 1_024
                )
            }
        )
        let available = try await service.availableBackups()
        let confirmed = try XCTUnwrap(available.first)
        let confirmedChunkCount = (original.count + 64 * 1_024 - 1) / (64 * 1_024)

        await assertRecoveryError(.backupChanged) {
            _ = try await service.restore(confirmed) {}
        }

        XCTAssertLessThanOrEqual(recorder.chunkCount, confirmedChunkCount)
        XCTAssertEqual(try Data(contentsOf: setup.database), original)
    }

    func testOversizedBackupSurfacesTheSupportedRestoreLimitWithoutMutation() async throws {
        let setup = try await makePopulatedLedger(quantity: 123)
        defer { try? FileManager.default.removeItem(at: setup.directory) }
        try await setup.ledger.shutdown()
        let original = try Data(contentsOf: setup.database)
        let backups = setup.directory.appending(path: "Backups", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: backups, withIntermediateDirectories: true)
        let oversized = backups.appending(path: "ledger-v2-100.sqlite")
        try Data(repeating: 0x5a, count: 128 * 1_024).write(to: oversized)
        let service = DatabaseRecoveryService(
            databaseURL: setup.database,
            backupDirectory: backups,
            stageHandler: { _ in },
            maximumRecoveryImageBytes: 64 * 1_024
        )

        await assertRecoveryError(.backupTooLarge(maximumBytes: 64 * 1_024)) {
            _ = try await service.availableBackups()
        }

        XCTAssertEqual(try Data(contentsOf: setup.database), original)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: backups.path), [oversized.lastPathComponent])
    }

    func testBelowLimitSparseBackupIsRejectedByAllocatedBlockCheckWithoutMutation() async throws {
        let setup = try await makePopulatedLedger(quantity: 124)
        defer { try? FileManager.default.removeItem(at: setup.directory) }
        try await setup.ledger.shutdown()
        let original = try Data(contentsOf: setup.database)
        let backups = setup.directory.appending(path: "Backups", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: backups, withIntermediateDirectories: true)
        let sparse = backups.appending(path: "ledger-v2-100.sqlite")
        let descriptor = Darwin.open(sparse.path, O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw RecoveryTestError.rollbackFailed }
        guard ftruncate(descriptor, 128 * 1_024) == 0 else {
            Darwin.close(descriptor)
            throw RecoveryTestError.rollbackFailed
        }
        Darwin.close(descriptor)
        let service = DatabaseRecoveryService(
            databaseURL: setup.database,
            backupDirectory: backups,
            stageHandler: { _ in },
            maximumRecoveryImageBytes: 256 * 1_024
        )

        let available = try await service.availableBackups()

        guard available.isEmpty else { throw RecoveryInvariantTestError.sparseBackupAccepted }
        XCTAssertEqual(try Data(contentsOf: setup.database), original)
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: backups.path),
            [sparse.lastPathComponent]
        )
    }

    func testRealV1BackupMigratesInMemoryWithoutTouchingBackupDirectory() async throws {
        let setup = try await makePopulatedLedger(quantity: 125)
        defer { try? FileManager.default.removeItem(at: setup.directory) }
        try await setup.ledger.shutdown()
        let backups = setup.directory.appending(path: "Backups", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: backups, withIntermediateDirectories: true)
        let backup = backups.appending(path: "ledger-v1-100.sqlite")
        let v1 = try SQLiteConnection(url: backup)
        try DatabaseMigrator(
            connection: v1,
            backupDirectory: backups,
            migrations: [Migrations.v1]
        ).migrate()
        try v1.execute("""
            INSERT INTO daily_usage VALUES(
              '2026-08-05', 'Europe/Amsterdam', 'codex', 'gpt-v1',
              'input_uncached', 'additive', 127
            );
            INSERT INTO price_rates VALUES(
              'codex', 'gpt-v1', 'input_uncached', '2.5', '2026-01-01', NULL,
              'https://example.com/pricing', '2026-08-01', 'v1-catalog'
            );
            INSERT INTO model_aliases VALUES(
              'codex', 'gpt-v1', 'gpt-v1', '2026-01-01', NULL, 'v1-catalog'
            );
            INSERT INTO catalog_imports VALUES(
              'v1-catalog', 1, 'bundled', '2026-08-01T00:00:00Z', 1,
              'validated', '{}'
            );
            """)
        try v1.checkpointWAL()
        try v1.close()
        let backupBytes = try Data(contentsOf: backup)
        let backupNames = try FileManager.default.contentsOfDirectory(atPath: backups.path)
        let service = DatabaseRecoveryService(databaseURL: setup.database, backupDirectory: backups)
        let available = try await service.availableBackups()
        let confirmed = try XCTUnwrap(available.first)

        _ = try await service.restore(confirmed) {}

        let restored = try SQLiteLedger(databaseURL: setup.database, backupDirectory: backups)
        try await restored.migrate()
        let rows = try await restored.usageRows(in: nil, calendar: calendar)
        let pricing = try await restored.pricingSnapshot()
        try await restored.shutdown()
        guard rows.map(\.quantity) == [127],
              pricing.catalogIDs == ["v1-catalog"],
              pricing.rates.map(\.usdPerMillion) == [Decimal(string: "2.5")!] else {
            throw RecoveryInvariantTestError.v1MigrationLostData
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: backups.path), backupNames)
        XCTAssertEqual(try Data(contentsOf: backup), backupBytes)
    }

    func testPreservationFailureCanRetryRetainedSnapshotIntoDurableNamedArtifact() async throws {
        let setup = try await makePopulatedLedger(quantity: 129)
        defer { try? FileManager.default.removeItem(at: setup.directory) }
        try await setup.ledger.shutdown()
        let original = try Data(contentsOf: setup.database)
        let backups = setup.directory.appending(path: "Backups", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: backups, withIntermediateDirectories: true)
        let replacement = try await databaseBytes(quantity: 131)
        let backup = backups.appending(path: "ledger-v2-100.sqlite")
        try replacement.write(to: backup)
        let service = DatabaseRecoveryService(
            databaseURL: setup.database,
            backupDirectory: backups,
            stageHandler: { stage in
                guard stage == .afterValidation else { return }
                let names = try FileManager.default.contentsOfDirectory(atPath: setup.directory.path)
                guard let snapshot = names.first(where: { $0.hasPrefix(".tokenboard-pre-restore-") }) else {
                    throw RecoveryInvariantTestError.missingNamedSnapshot
                }
                try FileManager.default.removeItem(at: setup.directory.appending(path: snapshot))
            }
        )
        let available = try await service.availableBackups()
        let confirmed = try XCTUnwrap(available.first)
        await assertRecoveryError(.preservationRetryRequired) {
            _ = try await service.restore(confirmed) {}
        }

        try await service.retryPreservation()

        let artifacts = try FileManager.default.contentsOfDirectory(atPath: setup.directory.path)
            .filter(Self.isCanonicalRecoverySnapshotName)
        guard artifacts.count == 1 else { throw RecoveryInvariantTestError.retryArtifactMissing }
        let artifact = setup.directory.appending(path: artifacts[0])
        var information = stat()
        guard lstat(artifact.path, &information) == 0,
              information.st_mode & S_IFMT == S_IFREG,
              information.st_nlink == 1,
              information.st_mode & (S_IWUSR | S_IWGRP | S_IWOTH) == 0,
              try Data(contentsOf: artifact) == original else {
            throw RecoveryInvariantTestError.retryArtifactInvalid
        }
        let restored = try SQLiteLedger(databaseURL: setup.database, backupDirectory: backups)
        try await restored.migrate()
        let quantities = try await restored.usageRows(in: nil, calendar: calendar).map(\.quantity)
        try await restored.shutdown()
        guard quantities == [131] else {
            throw RecoveryInvariantTestError.retryInstalledDatabaseInvalid
        }
        XCTAssertEqual(try Data(contentsOf: backup), replacement)
    }

    func testUnretainableSnapshotFailureIsTerminalAndOffersNoRetryClaim() async throws {
        let setup = try await makePopulatedLedger(quantity: 133)
        defer { try? FileManager.default.removeItem(at: setup.directory) }
        try await setup.ledger.shutdown()
        let backups = setup.directory.appending(path: "Backups", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: backups, withIntermediateDirectories: true)
        try await databaseBytes(quantity: 135).write(to: backups.appending(path: "ledger-v2-100.sqlite"))
        let service = DatabaseRecoveryService(
            databaseURL: setup.database,
            backupDirectory: backups,
            stageHandler: { stage in
                guard stage == .afterValidation else { return }
                let names = try FileManager.default.contentsOfDirectory(atPath: setup.directory.path)
                guard let snapshot = names.first(where: { $0.hasPrefix(".tokenboard-pre-restore-") }) else {
                    throw RecoveryInvariantTestError.missingNamedSnapshot
                }
                try FileManager.default.removeItem(at: setup.directory.appending(path: snapshot))
            },
            fileOperationHandler: { operation in
                if operation == .retainParentDescriptor { throw RecoveryTestError.shutdownFailed }
            }
        )
        let available = try await service.availableBackups()
        let confirmed = try XCTUnwrap(available.first)

        await assertRecoveryError(.preservationFailed) {
            _ = try await service.restore(confirmed) {}
        }
        await assertRecoveryError(.preservationFailed) {
            try await service.retryPreservation()
        }
    }

    func testFailedPreservationRetryRemovesPartialArtifactAndKeepsRetryAvailable() async throws {
        let setup = try await makePopulatedLedger(quantity: 137)
        defer { try? FileManager.default.removeItem(at: setup.directory) }
        try await setup.ledger.shutdown()
        let backups = setup.directory.appending(path: "Backups", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: backups, withIntermediateDirectories: true)
        try await databaseBytes(quantity: 139).write(to: backups.appending(path: "ledger-v2-100.sqlite"))
        let service = DatabaseRecoveryService(
            databaseURL: setup.database,
            backupDirectory: backups,
            stageHandler: { stage in
                guard stage == .afterValidation else { return }
                let names = try FileManager.default.contentsOfDirectory(atPath: setup.directory.path)
                guard let snapshot = names.first(where: { $0.hasPrefix(".tokenboard-pre-restore-") }) else {
                    throw RecoveryInvariantTestError.missingNamedSnapshot
                }
                try FileManager.default.removeItem(at: setup.directory.appending(path: snapshot))
            },
            fileOperationHandler: { operation in
                if operation == .syncPreservationArtifact { throw RecoveryTestError.shutdownFailed }
            }
        )
        let available = try await service.availableBackups()
        let confirmed = try XCTUnwrap(available.first)
        await assertRecoveryError(.preservationRetryRequired) {
            _ = try await service.restore(confirmed) {}
        }

        await assertRecoveryError(.preservationRetryRequired) {
            try await service.retryPreservation()
        }

        let residues = try FileManager.default.contentsOfDirectory(atPath: setup.directory.path)
            .filter {
                $0.hasPrefix(".tokenboard-preservation-stage-")
                    || Self.isCanonicalRecoverySnapshotName($0)
            }
        guard residues.isEmpty else { throw RecoveryInvariantTestError.partialRetryArtifactLeftBehind }
    }

    func testPruningIgnoresStageWritableMalformedPartialAndHardLinkedLookalikes() async throws {
        let setup = try await makePopulatedLedger(quantity: 140)
        defer { try? FileManager.default.removeItem(at: setup.directory) }
        try await setup.ledger.shutdown()
        let original = try Data(contentsOf: setup.database)
        let backups = setup.directory.appending(path: "Backups", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: backups, withIntermediateDirectories: true)
        try await databaseBytes(quantity: 142).write(to: backups.appending(path: "ledger-v2-100.sqlite"))

        let olderName = Self.canonicalRecoverySnapshotName(UUID())
        let newestValidName = Self.canonicalRecoverySnapshotName(UUID())
        for (name, date) in [
            (olderName, Date(timeIntervalSince1970: 100)),
            (newestValidName, Date(timeIntervalSince1970: 200))
        ] {
            let url = setup.directory.appending(path: name)
            try original.write(to: url)
            try FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: S_IRUSR), .modificationDate: date],
                ofItemAtPath: url.path
            )
        }

        let writableName = Self.canonicalRecoverySnapshotName(UUID())
        let writable = setup.directory.appending(path: writableName)
        try original.write(to: writable)
        try setModificationDate(Date(timeIntervalSince1970: 9_000), for: writable)

        let malformed = setup.directory.appending(path: ".tokenboard-pre-restore-not-a-uuid.sqlite")
        try original.write(to: malformed)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: S_IRUSR), .modificationDate: Date(timeIntervalSince1970: 8_000)],
            ofItemAtPath: malformed.path
        )

        let partialName = Self.canonicalRecoverySnapshotName(UUID())
        let partial = setup.directory.appending(path: partialName)
        try Data("partial".utf8).write(to: partial)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: S_IRUSR), .modificationDate: Date(timeIntervalSince1970: 7_000)],
            ofItemAtPath: partial.path
        )

        let stage = setup.directory.appending(
            path: ".tokenboard-preservation-stage-\(UUID().uuidString).sqlite"
        )
        try Data("crash-stage".utf8).write(to: stage)
        let malformedStage = setup.directory.appending(
            path: ".tokenboard-preservation-stage-not-a-uuid.sqlite"
        )
        try Data("malformed-stage".utf8).write(to: malformedStage)
        let stageSymlink = setup.directory.appending(
            path: ".tokenboard-preservation-stage-\(UUID().uuidString).sqlite"
        )
        try FileManager.default.createSymbolicLink(at: stageSymlink, withDestinationURL: malformedStage)
        let stageHardLinkSource = setup.directory.appending(path: ".stage-hardlink-source")
        try Data("hard-linked-stage".utf8).write(to: stageHardLinkSource)
        let stageHardLink = setup.directory.appending(
            path: ".tokenboard-preservation-stage-\(UUID().uuidString).sqlite"
        )
        try FileManager.default.linkItem(at: stageHardLinkSource, to: stageHardLink)

        let hardLinkSource = setup.directory.appending(path: ".recovery-hardlink-source")
        try original.write(to: hardLinkSource)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: S_IRUSR)],
            ofItemAtPath: hardLinkSource.path
        )
        let hardLinkedName = Self.canonicalRecoverySnapshotName(UUID())
        let hardLinked = setup.directory.appending(path: hardLinkedName)
        try FileManager.default.linkItem(at: hardLinkSource, to: hardLinked)

        let service = DatabaseRecoveryService(databaseURL: setup.database, backupDirectory: backups)
        let available = try await service.availableBackups()
        let confirmed = try XCTUnwrap(available.first)
        _ = try await service.restore(confirmed) {}

        let names = try FileManager.default.contentsOfDirectory(atPath: setup.directory.path)
        guard !names.contains(olderName),
              names.contains(newestValidName),
              names.contains(writableName),
              names.contains(malformed.lastPathComponent),
              names.contains(partialName),
              !names.contains(stage.lastPathComponent),
              names.contains(malformedStage.lastPathComponent),
              names.contains(stageSymlink.lastPathComponent),
              names.contains(stageHardLink.lastPathComponent),
              names.contains(hardLinkedName) else {
            throw RecoveryInvariantTestError.invalidSnapshotPruning
        }
    }

    func testPreservationRetryPublishesWithoutOverwriteAndCleansItsStage() async throws {
        let setup = try await makePopulatedLedger(quantity: 144)
        defer { try? FileManager.default.removeItem(at: setup.directory) }
        try await setup.ledger.shutdown()
        let backups = setup.directory.appending(path: "Backups", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: backups, withIntermediateDirectories: true)
        try await databaseBytes(quantity: 146).write(to: backups.appending(path: "ledger-v2-100.sqlite"))
        let collision = RecoveryCollisionInstaller(directory: setup.directory)
        let service = DatabaseRecoveryService(
            databaseURL: setup.database,
            backupDirectory: backups,
            stageHandler: { stage in
                guard stage == .afterValidation else { return }
                let names = try FileManager.default.contentsOfDirectory(atPath: setup.directory.path)
                guard let snapshot = names.first(where: Self.isCanonicalRecoverySnapshotName) else {
                    throw RecoveryInvariantTestError.missingNamedSnapshot
                }
                try FileManager.default.removeItem(at: setup.directory.appending(path: snapshot))
            },
            fileOperationHandler: { operation in
                if operation == .beforePreservationPublish {
                    try collision.installForCurrentStage()
                }
            }
        )
        let available = try await service.availableBackups()
        let confirmed = try XCTUnwrap(available.first)
        await assertRecoveryError(.preservationRetryRequired) {
            _ = try await service.restore(confirmed) {}
        }

        await assertRecoveryError(.preservationRetryRequired) {
            try await service.retryPreservation()
        }

        guard let final = collision.finalURL,
              try Data(contentsOf: final) == RecoveryCollisionInstaller.sentinel,
              try FileManager.default.contentsOfDirectory(atPath: setup.directory.path)
                .contains(where: { $0.hasPrefix(".tokenboard-preservation-stage-") }) == false else {
            throw RecoveryInvariantTestError.preservationCollisionOverwritten
        }
    }

    func testPreservationRetryStreamsSnapshotLargerThanMigrationCapExactly() async throws {
        let setup = try await makePopulatedLedger(quantity: 148)
        defer { try? FileManager.default.removeItem(at: setup.directory) }
        try await setup.ledger.shutdown()
        let padding = try SQLiteConnection(url: setup.database)
        try padding.execute("CREATE TABLE retention_padding(value BLOB NOT NULL);")
        try padding.execute("INSERT INTO retention_padding VALUES(zeroblob(1048576));")
        try padding.checkpointWAL()
        try padding.close()
        let original = try Data(contentsOf: setup.database)
        let backups = setup.directory.appending(path: "Backups", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: backups, withIntermediateDirectories: true)
        let replacement = try await databaseBytes(quantity: 150)
        try replacement.write(to: backups.appending(path: "ledger-v2-100.sqlite"))
        guard original.count > replacement.count else {
            throw RecoveryInvariantTestError.largeSnapshotFixtureInvalid
        }
        let operations = RecoveryOperationRecorder()
        let service = DatabaseRecoveryService(
            databaseURL: setup.database,
            backupDirectory: backups,
            stageHandler: { stage in
                guard stage == .afterValidation else { return }
                let names = try FileManager.default.contentsOfDirectory(atPath: setup.directory.path)
                guard let snapshot = names.first(where: Self.isCanonicalRecoverySnapshotName) else {
                    throw RecoveryInvariantTestError.missingNamedSnapshot
                }
                try FileManager.default.removeItem(at: setup.directory.appending(path: snapshot))
            },
            fileOperationHandler: { operation in
                if operation == .preservationCopyChunk { operations.recordChunk() }
            },
            maximumRecoveryImageBytes: replacement.count
        )
        let available = try await service.availableBackups()
        let confirmed = try XCTUnwrap(available.first)
        await assertRecoveryError(.preservationRetryRequired) {
            _ = try await service.restore(confirmed) {}
        }
        let installedBeforeRetry = try Data(contentsOf: setup.database)

        try await service.retryPreservation()

        let artifacts = try FileManager.default.contentsOfDirectory(atPath: setup.directory.path)
            .filter(Self.isCanonicalRecoverySnapshotName)
        guard artifacts.count == 1,
              operations.chunkCount > 1,
              try Data(contentsOf: setup.directory.appending(path: artifacts[0])) == original,
              try Data(contentsOf: setup.database) == installedBeforeRetry else {
            throw RecoveryInvariantTestError.largeSnapshotStreamingFailed
        }
    }

    func testSuccessfulRestoresRetainOnlyTheNewestTwoRecoverySnapshots() async throws {
        let setup = try await makePopulatedLedger(quantity: 141)
        defer { try? FileManager.default.removeItem(at: setup.directory) }
        try await setup.ledger.shutdown()
        let backups = setup.directory.appending(path: "Backups", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: backups, withIntermediateDirectories: true)
        let backup = backups.appending(path: "ledger-v2-100.sqlite")
        let replacement = try await databaseBytes(quantity: 143)
        try replacement.write(to: backup)
        let service = DatabaseRecoveryService(databaseURL: setup.database, backupDirectory: backups)
        let available = try await service.availableBackups()
        let confirmed = try XCTUnwrap(available.first)

        for _ in 0..<3 { _ = try await service.restore(confirmed) {} }

        let snapshots = try FileManager.default.contentsOfDirectory(atPath: setup.directory.path)
            .filter(Self.isCanonicalRecoverySnapshotName)
        guard snapshots.count == 2 else {
            throw RecoveryInvariantTestError.unboundedSnapshotRetention(snapshots.count)
        }
        XCTAssertEqual(try Data(contentsOf: backup), replacement)
    }

    func testRollbackFinalDigestRejectsMetadataRestoredByteMutationAfterAwait() async throws {
        let setup = try await makePopulatedLedger(quantity: 145)
        defer { try? FileManager.default.removeItem(at: setup.directory) }
        try await setup.ledger.shutdown()
        let backups = setup.directory.appending(path: "Backups", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: backups, withIntermediateDirectories: true)
        try await databaseBytes(quantity: 147).write(to: backups.appending(path: "ledger-v2-100.sqlite"))
        let service = DatabaseRecoveryService(
            databaseURL: setup.database,
            backupDirectory: backups,
            stageHandler: { stage in
                if stage == .afterReplacement { throw RecoveryTestError.shutdownFailed }
                if stage == .afterRollback {
                    try Self.mutateLastBytePreservingStat(at: setup.database)
                }
            }
        )
        let available = try await service.availableBackups()
        let confirmed = try XCTUnwrap(available.first)

        await assertRecoveryError(.rollbackFailed) {
            _ = try await service.restore(confirmed) {}
        }
    }

    private func databaseBytes(quantity: Int64) async throws -> Data {
        let setup = try await makePopulatedLedger(quantity: quantity)
        defer { try? FileManager.default.removeItem(at: setup.directory) }
        try await setup.ledger.shutdown()
        return try Data(contentsOf: setup.database)
    }

    private func databaseQuantities(at database: URL, backups: URL) async throws -> [Int64] {
        let ledger = try SQLiteLedger(databaseURL: database, backupDirectory: backups)
        try await ledger.migrate()
        let quantities = try await ledger.usageRows(in: nil, calendar: calendar).map(\.quantity)
        try await ledger.shutdown()
        return quantities
    }

    private func makePopulatedLedger(quantity: Int64) async throws -> (
        directory: URL,
        database: URL,
        ledger: SQLiteLedger
    ) {
        let directory = try makeDirectory()
        let database = directory.appending(path: "ledger.sqlite")
        let ledger = try SQLiteLedger(
            databaseURL: database,
            backupDirectory: directory.appending(path: "Backups")
        )
        try await ledger.migrate()
        let usage = try NormalizedUsage(
            provider: .codex,
            observedModelID: "gpt-test",
            timestamp: ISO8601DateFormatter().date(from: "2026-08-05T10:00:00Z")!,
            metrics: [.inputUncached: quantity],
            stableSourceID: "content-free-source",
            stableUsageID: "content-free-usage"
        )
        try await ledger.commit(
            [usage],
            skipped: [],
            checkpoint: SourceCheckpoint(
                fingerprint: String(repeating: "a", count: 64),
                provider: .codex,
                parserVersion: 1,
                byteOffset: 1,
                fileSize: 1,
                modificationTime: nil,
                lastUsageIdentityHash: String(repeating: "b", count: 64),
                lastCommittedLineHash: String(repeating: "c", count: 64),
                cumulativeMetrics: [:],
                adapterState: ["current_model": "gpt-test"]
            ),
            calendar: calendar
        )
        return (directory, database, ledger)
    }

    private func makeDirectory() throws -> URL {
        let directory = canonicalTestTemporaryDirectory
            .resolvingSymlinksInPath()
            .appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func setModificationDate(_ date: Date, for url: URL) throws {
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
    }

    private static func mutateLastBytePreservingStat(at url: URL) throws {
        let descriptor = Darwin.open(url.path, O_RDWR | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { throw RecoveryTestError.rollbackFailed }
        defer { Darwin.close(descriptor) }
        var information = stat()
        guard fstat(descriptor, &information) == 0, information.st_size > 0 else {
            throw RecoveryTestError.rollbackFailed
        }
        var byte: UInt8 = 0
        guard pread(descriptor, &byte, 1, information.st_size - 1) == 1 else {
            throw RecoveryTestError.rollbackFailed
        }
        byte ^= 0x01
        guard pwrite(descriptor, &byte, 1, information.st_size - 1) == 1 else {
            throw RecoveryTestError.rollbackFailed
        }
        var times = [information.st_atimespec, information.st_mtimespec]
        guard futimens(descriptor, &times) == 0 else { throw RecoveryTestError.rollbackFailed }
    }

    private static func canonicalRecoverySnapshotName(_ identifier: UUID) -> String {
        ".tokenboard-pre-restore-\(identifier.uuidString).sqlite"
    }

    private static func isCanonicalRecoverySnapshotName(_ name: String) -> Bool {
        let prefix = ".tokenboard-pre-restore-"
        let suffix = ".sqlite"
        guard name.hasPrefix(prefix), name.hasSuffix(suffix) else { return false }
        let start = name.index(name.startIndex, offsetBy: prefix.count)
        let end = name.index(name.endIndex, offsetBy: -suffix.count)
        let token = String(name[start..<end])
        return UUID(uuidString: token)?.uuidString == token
    }

    private func assertConnectionClosed(
        _ operation: () async throws -> Void,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            try await operation()
            XCTFail("expected connectionClosed", file: file, line: line)
        } catch let error as LedgerError {
            XCTAssertEqual(error, .connectionClosed, file: file, line: line)
        } catch {
            XCTFail("expected connectionClosed, received \(error)", file: file, line: line)
        }
    }
}

private enum RecoveryTestError: Error, Equatable {
    case shutdownFailed
    case rollbackFailed
}

private enum RecoveryInvariantTestError: Error {
    case missingNamedSnapshot
    case invalidNamedSnapshot
    case mutatedInstalledDatabaseAccepted
    case mutatedSnapshotAccepted
    case installedBackupContentsInvalid
    case boundaryRestoreFailed
    case sparseBackupAccepted
    case v1MigrationLostData
    case retryArtifactMissing
    case retryArtifactInvalid
    case retryInstalledDatabaseInvalid
    case partialRetryArtifactLeftBehind
    case unboundedSnapshotRetention(Int)
    case invalidSnapshotPruning
    case preservationCollisionOverwritten
    case largeSnapshotFixtureInvalid
    case largeSnapshotStreamingFailed
}

private final class RecoveryOperationRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var chunks = 0
    var chunkCount: Int { lock.withLock { chunks } }
    func recordChunk() { lock.withLock { chunks += 1 } }
}

private final class RecoveryBackupGrower: @unchecked Sendable {
    private let lock = NSLock()
    private var didAppend = false

    func appendOnce(to url: URL, bytes: Int) throws {
        try lock.withLock {
            guard !didAppend else { return }
            didAppend = true
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(repeating: 0x5a, count: bytes))
            try handle.synchronize()
        }
    }
}

private final class RecoveryCollisionInstaller: @unchecked Sendable {
    static let sentinel = Data("existing-final".utf8)
    private let directory: URL
    private let lock = NSLock()
    private(set) var finalURL: URL?

    init(directory: URL) {
        self.directory = directory
    }

    func installForCurrentStage() throws {
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        guard let stage = names.first(where: { $0.hasPrefix(".tokenboard-preservation-stage-") }) else {
            throw RecoveryInvariantTestError.missingNamedSnapshot
        }
        let stagePrefix = ".tokenboard-preservation-stage-"
        let token = stage.dropFirst(stagePrefix.count).dropLast(".sqlite".count)
        let final = directory.appending(path: ".tokenboard-pre-restore-\(token).sqlite")
        try Self.sentinel.write(to: final, options: .withoutOverwriting)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: S_IRUSR)],
            ofItemAtPath: final.path
        )
        lock.withLock { finalURL = final }
    }
}

private actor RecoveryGate {
    private var entered = false
    private var resumed = false
    private var enteredWaiters: [CheckedContinuation<Void, Never>] = []
    private var resumeWaiters: [CheckedContinuation<Void, Never>] = []

    func enter() {
        entered = true
        enteredWaiters.forEach { $0.resume() }
        enteredWaiters.removeAll()
    }

    func waitUntilEntered() async {
        guard !entered else { return }
        await withCheckedContinuation { enteredWaiters.append($0) }
    }

    func wait() async {
        guard !resumed else { return }
        await withCheckedContinuation { resumeWaiters.append($0) }
    }

    func resume() {
        resumed = true
        resumeWaiters.forEach { $0.resume() }
        resumeWaiters.removeAll()
    }
}

private func XCTAssertThrowsErrorAsync(
    _ expression: () async throws -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        try await expression()
        XCTFail("expected expression to throw", file: file, line: line)
    } catch {
    }
}

private func assertRecoveryError(
    _ expected: DatabaseRecoveryError,
    _ operation: () async throws -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        try await operation()
        XCTFail("expected \(expected)", file: file, line: line)
    } catch let error as DatabaseRecoveryError {
        XCTAssertEqual(error, expected, file: file, line: line)
    } catch {
        XCTFail("expected \(expected), received \(error)", file: file, line: line)
    }
}

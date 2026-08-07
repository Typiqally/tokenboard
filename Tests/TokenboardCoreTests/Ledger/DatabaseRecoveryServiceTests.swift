import Foundation
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
        for file in [oldest, tiedA, tiedB] + impostors {
            try Data(file.lastPathComponent.utf8).write(to: file)
        }
        try setModificationDate(Date(timeIntervalSince1970: 100), for: oldest)
        try setModificationDate(Date(timeIntervalSince1970: 200), for: tiedA)
        try setModificationDate(Date(timeIntervalSince1970: 200), for: tiedB)
        for file in impostors {
            try setModificationDate(Date(timeIntervalSince1970: 300), for: file)
        }

        let service = DatabaseRecoveryService(databaseURL: database, backupDirectory: backups)
        let result = try await service.availableBackups()

        XCTAssertEqual(result.map(\.filename), [
            "ledger-v2-200.sqlite",
            "ledger-v1-200.sqlite",
            "ledger-v1-100.sqlite"
        ])
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
        try Data("backup-sentinel".utf8).write(to: backup)
        let databaseBefore = try Data(contentsOf: setup.database)
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

    func testInvalidLatestBackupRollsBackOriginalAndPreservesBackup() async throws {
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
        let confirmed = try XCTUnwrap(available.first)

        await XCTAssertThrowsErrorAsync {
            _ = try await service.restore(confirmed) {}
        }

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
        let backupBytes = Data(repeating: 0x5a, count: 128 * 1024)
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
        let invalid = Data(repeating: 0xA7, count: 512)
        try invalid.write(to: backup)
        let service = DatabaseRecoveryService(
            databaseURL: setup.database,
            backupDirectory: backups,
            stageHandler: { stage in
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
        XCTAssertEqual(try Data(contentsOf: backup), invalid)
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
        let directory = FileManager.default.temporaryDirectory
            .resolvingSymlinksInPath()
            .appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func setModificationDate(_ date: Date, for url: URL) throws {
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
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

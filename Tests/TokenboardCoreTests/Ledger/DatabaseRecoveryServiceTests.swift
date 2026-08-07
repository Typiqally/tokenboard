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

        XCTAssertEqual(result.map(\.url.lastPathComponent), [
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
        let restore = Task {
            try await service.restoreLatest {
                await gate.enter()
                await gate.wait()
                try await corruptingLedger.shutdown()
                try Data("wal".utf8).write(to: wal)
                try Data("shm".utf8).write(to: shm)
                try Data("keep".utf8).write(to: lookalike)
            }
        }
        await gate.waitUntilEntered()
        XCTAssertNotEqual(try Data(contentsOf: setup.database), expectedBytes)
        await gate.resume()
        let restoredBackup = try await restore.value

        XCTAssertEqual(restoredBackup.url, backup)
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

        do {
            _ = try await service.restoreLatest { throw RecoveryTestError.shutdownFailed }
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

        await XCTAssertThrowsErrorAsync {
            _ = try await service.restoreLatest {}
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
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
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

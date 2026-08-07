import CSQLite
import Darwin
import Foundation
import XCTest
@testable import TokenboardCore

final class DatabaseMigratorTests: XCTestCase {
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func testV1CreatesEveryRequiredTableAndIsIdempotent() throws {
        let directory = try temporaryDirectory()
        let connection = try SQLiteConnection(url: directory.appending(path: "ledger.sqlite"))
        let migrator = DatabaseMigrator(
            connection: connection,
            backupDirectory: directory.appending(path: "Backups"),
            migrations: Migrations.all
        )
        try migrator.migrate()
        try migrator.migrate()
        let names = try connection.queryStrings(
            "SELECT name FROM sqlite_master WHERE type='table' ORDER BY name"
        )
        for required in ["app_metadata", "daily_usage", "source_checkpoints", "skipped_records", "price_rates", "model_aliases", "catalog_imports", "fx_rates", "schema_migrations"] {
            XCTAssertTrue(names.contains(required), "missing \(required)")
        }
    }

    func testV3AddsExchangeRatesWithoutChangingV2PricingData() throws {
        let directory = try temporaryDirectory()
        let database = directory.appending(path: "ledger.sqlite")
        let backups = directory.appending(path: "Backups")
        let connection = try SQLiteConnection(url: database)
        try DatabaseMigrator(
            connection: connection,
            backupDirectory: backups,
            migrations: [Migrations.v1, Migrations.v2]
        ).migrate()
        try connection.execute("INSERT INTO app_metadata(key, value) VALUES('sentinel', X'01');")

        try DatabaseMigrator(
            connection: connection,
            backupDirectory: backups,
            migrations: Migrations.all
        ).migrate()

        XCTAssertEqual(try connection.userVersion, 3)
        XCTAssertEqual(
            try connection.queryStrings("SELECT name FROM sqlite_master WHERE type='table' AND name='fx_rates';"),
            ["fx_rates"]
        )
        XCTAssertEqual(
            try connection.queryStrings("SELECT hex(value) FROM app_metadata WHERE key='sentinel';"),
            ["01"]
        )
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: backups.path)
                .filter { $0.hasSuffix(".sqlite") }.count,
            1
        )
    }

    func testLegacyCompactSchemaMigrationsDefinitionCanUpgrade() throws {
        let directory = try temporaryDirectory()
        let connection = try SQLiteConnection(url: directory.appending(path: "ledger.sqlite"))
        try connection.execute(
            "CREATE TABLE schema_migrations(version INTEGER PRIMARY KEY, name TEXT NOT NULL, checksum TEXT NOT NULL, applied_at TEXT NOT NULL);"
        )
        try installMigration(Migrations.v1, in: connection)
        try installMigration(Migrations.v2, in: connection)

        try DatabaseMigrator(
            connection: connection,
            backupDirectory: directory.appending(path: "Backups"),
            migrations: Migrations.all
        ).migrate()

        XCTAssertEqual(try connection.userVersion, 3)
        XCTAssertEqual(
            try connection.queryStrings(
                "SELECT name FROM sqlite_master WHERE type='table' AND name='fx_rates';"
            ),
            ["fx_rates"]
        )
    }

    func testFailedMigrationRollsBack() throws {
        let directory = try temporaryDirectory()
        let connection = try SQLiteConnection(url: directory.appending(path: "ledger.sqlite"))
        let migrations = [
            Migration(version: 1, name: "valid", sql: "CREATE TABLE retained(value INTEGER);"),
            Migration(
                version: 2,
                name: "partially invalid",
                sql: "CREATE TABLE broken(value INTEGER); CREATE TABL invalid(value INTEGER);"
            )
        ]
        let migrator = DatabaseMigrator(
            connection: connection,
            backupDirectory: directory.appending(path: "Backups"),
            migrations: migrations
        )
        XCTAssertThrowsError(try migrator.migrate())
        XCTAssertFalse(try connection.queryStrings("SELECT name FROM sqlite_master").contains("broken"))
        XCTAssertEqual(try connection.queryStrings("SELECT version FROM schema_migrations ORDER BY version"), ["1"])
        XCTAssertEqual(try connection.userVersion, 1)
    }

    private func installMigration(
        _ migration: Migration,
        in connection: SQLiteConnection
    ) throws {
        try connection.execute(migration.sql)
        try connection.execute(
            "INSERT INTO schema_migrations VALUES(\(migration.version), '\(migration.name)', '\(databaseMigrationChecksum(migration.sql))', '2026-08-07T00:00:00Z');"
        )
        try connection.setUserVersion(migration.version)
    }

    func testPendingUpgradeCreatesBackupAndKeepsNewestTwo() throws {
        let directory = try temporaryDirectory()
        let database = directory.appending(path: "ledger.sqlite")
        let backupDirectory = directory.appending(path: "Backups")
        let connection = try SQLiteConnection(url: database)
        try DatabaseMigrator(connection: connection, backupDirectory: backupDirectory, migrations: [
            Migration(version: 1, name: "one", sql: "CREATE TABLE one(value INTEGER);")
        ]).migrate()
        try DatabaseMigrator(connection: connection, backupDirectory: backupDirectory, migrations: [
            Migration(version: 1, name: "one", sql: "CREATE TABLE one(value INTEGER);"),
            Migration(version: 2, name: "two", sql: "CREATE TABLE two(value INTEGER);")
        ]).migrate()
        try DatabaseMigrator(connection: connection, backupDirectory: backupDirectory, migrations: [
            Migration(version: 1, name: "one", sql: "CREATE TABLE one(value INTEGER);"),
            Migration(version: 2, name: "two", sql: "CREATE TABLE two(value INTEGER);"),
            Migration(version: 3, name: "three", sql: "CREATE TABLE three(value INTEGER);")
        ]).migrate()
        try DatabaseMigrator(connection: connection, backupDirectory: backupDirectory, migrations: [
            Migration(version: 1, name: "one", sql: "CREATE TABLE one(value INTEGER);"),
            Migration(version: 2, name: "two", sql: "CREATE TABLE two(value INTEGER);"),
            Migration(version: 3, name: "three", sql: "CREATE TABLE three(value INTEGER);"),
            Migration(version: 4, name: "four", sql: "CREATE TABLE four(value INTEGER);")
        ]).migrate()
        let backups = try FileManager.default.contentsOfDirectory(at: backupDirectory, includingPropertiesForKeys: nil)
        XCTAssertEqual(backups.count, 2)
    }

    func testChangedAppliedMigrationChecksumIsRejected() throws {
        let directory = try temporaryDirectory()
        let connection = try SQLiteConnection(url: directory.appending(path: "ledger.sqlite"))
        let backupDirectory = directory.appending(path: "Backups")
        try DatabaseMigrator(connection: connection, backupDirectory: backupDirectory, migrations: [
            Migration(version: 1, name: "one", sql: "CREATE TABLE one(value INTEGER);")
        ]).migrate()
        XCTAssertThrowsError(try DatabaseMigrator(connection: connection, backupDirectory: backupDirectory, migrations: [
            Migration(version: 1, name: "one", sql: "CREATE TABLE one(changed TEXT);")
        ]).migrate())
    }

    func testMigrationDefinitionsMustBeUniqueAndContiguous() throws {
        let directory = try temporaryDirectory()
        let connection = try SQLiteConnection(url: directory.appending(path: "ledger.sqlite"))
        let backupDirectory = directory.appending(path: "Backups")

        XCTAssertThrowsError(try DatabaseMigrator(connection: connection, backupDirectory: backupDirectory, migrations: [
            Migration(version: 2, name: "sparse", sql: "CREATE TABLE sparse(value INTEGER);")
        ]).migrate())
        XCTAssertThrowsError(try DatabaseMigrator(connection: connection, backupDirectory: backupDirectory, migrations: [
            Migration(version: 1, name: "one", sql: "CREATE TABLE one(value INTEGER);"),
            Migration(version: 1, name: "duplicate", sql: "CREATE TABLE duplicate(value INTEGER);")
        ]).migrate())
        XCTAssertFalse(try connection.queryStrings(
            "SELECT name FROM sqlite_master WHERE name = 'schema_migrations';"
        ).contains("schema_migrations"))
    }

    func testForeignVersionZeroDatabaseIsRejectedWithoutLogicalOrByteMutation() throws {
        let directory = try temporaryDirectory()
        let database = directory.appending(path: "ledger.sqlite")
        let connection = try SQLiteConnection(url: database)
        try connection.execute("CREATE TABLE foreign_table(value TEXT);")
        try connection.execute("INSERT INTO foreign_table VALUES('sentinel');")
        try connection.checkpointWAL()
        let before = try Data(contentsOf: database)

        XCTAssertThrowsError(try DatabaseMigrator(
            connection: connection,
            backupDirectory: directory.appending(path: "Backups"),
            migrations: Migrations.all
        ).migrate())

        XCTAssertEqual(try Data(contentsOf: database), before)
        XCTAssertEqual(try connection.queryStrings("SELECT value FROM foreign_table;"), ["sentinel"])
        XCTAssertEqual(try connection.userVersion, 0)
        XCTAssertEqual(
            try connection.queryStrings("SELECT name FROM sqlite_master WHERE name = 'schema_migrations';"),
            []
        )
    }

    func testFutureVersionWithoutMigrationTableIsRejectedWithoutCreatingItOrABackup() throws {
        let directory = try temporaryDirectory()
        let database = directory.appending(path: "ledger.sqlite")
        let backups = directory.appending(path: "Backups")
        let connection = try SQLiteConnection(url: database)
        try connection.execute("CREATE TABLE future_table(value TEXT);")
        try connection.setUserVersion(99)
        try connection.checkpointWAL()
        let before = try Data(contentsOf: database)

        XCTAssertThrowsError(try DatabaseMigrator(
            connection: connection,
            backupDirectory: backups,
            migrations: Migrations.all
        ).migrate())

        XCTAssertEqual(try Data(contentsOf: database), before)
        XCTAssertEqual(
            try connection.queryStrings("SELECT name FROM sqlite_master WHERE name = 'schema_migrations';"),
            []
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: backups.path))
    }

    func testAppliedNameAndChecksumPreflightRejectsBeforeBackupOrSchemaWrite() throws {
        let directory = try temporaryDirectory()
        let database = directory.appending(path: "ledger.sqlite")
        let backups = directory.appending(path: "Backups")
        let connection = try SQLiteConnection(url: database)
        try DatabaseMigrator(
            connection: connection,
            backupDirectory: backups,
            migrations: [Migration(version: 1, name: "one", sql: "CREATE TABLE one(value INTEGER);")]
        ).migrate()
        try connection.execute("UPDATE schema_migrations SET name = 'tampered' WHERE version = 1;")
        try connection.checkpointWAL()
        let before = try Data(contentsOf: database)

        XCTAssertThrowsError(try DatabaseMigrator(
            connection: connection,
            backupDirectory: backups,
            migrations: [
                Migration(version: 1, name: "one", sql: "CREATE TABLE one(value INTEGER);"),
                Migration(version: 2, name: "two", sql: "CREATE TABLE two(value INTEGER);")
            ]
        ).migrate())

        XCTAssertEqual(try Data(contentsOf: database), before)
        XCTAssertFalse(FileManager.default.fileExists(atPath: backups.path))
    }

    func testBackupUsesUniqueRecoveryCompatibleNameAndRetentionPreservesUnrelatedEntries() async throws {
        let directory = try temporaryDirectory()
        let database = directory.appending(path: "ledger.sqlite")
        let backups = directory.appending(path: "Backups")
        let connection = try SQLiteConnection(url: database)
        try DatabaseMigrator(
            connection: connection,
            backupDirectory: backups,
            migrations: [Migrations.v1]
        ).migrate()
        try FileManager.default.createDirectory(at: backups, withIntermediateDirectories: true)
        let unrelated = backups.appending(path: "notes.txt")
        try Data("keep".utf8).write(to: unrelated)
        let validBackup = try validV1BackupBytes()
        for second in 100...102 {
            let legacy = backups.appending(path: "ledger-v1-\(second).sqlite")
            try validBackup.write(to: legacy)
            try FileManager.default.setAttributes(
                [.modificationDate: Date(timeIntervalSince1970: TimeInterval(second))],
                ofItemAtPath: legacy.path
            )
        }

        try DatabaseMigrator(
            connection: connection,
            backupDirectory: backups,
            migrations: Migrations.all
        ).migrate()

        let names = try FileManager.default.contentsOfDirectory(atPath: backups.path)
        XCTAssertTrue(names.contains("notes.txt"))
        XCTAssertFalse(names.contains { $0.hasSuffix("-journal") || $0.hasSuffix("-wal") || $0.hasSuffix("-shm") })
        let backupNames = names.filter { $0.hasPrefix("ledger-v") && $0.hasSuffix(".sqlite") }
        XCTAssertEqual(backupNames.count, 2)
        XCTAssertTrue(backupNames.contains { $0.split(separator: "-").count > 4 })
        let available = try await DatabaseRecoveryService(
            databaseURL: database,
            backupDirectory: backups
        ).availableBackups()
        XCTAssertTrue(available.contains { backupNames.contains($0.filename) })
    }

    func testDeserializeFailureTransfersStorageWithoutCallerRelease() throws {
        let directory = try temporaryDirectory()
        let database = directory.appending(path: "ledger.sqlite")
        let backups = directory.appending(path: "Backups")
        let connection = try SQLiteConnection(url: database)
        try DatabaseMigrator(
            connection: connection,
            backupDirectory: backups,
            migrations: [Migrations.v1]
        ).migrate()
        var allocated: UnsafeMutableRawPointer?
        var callerReleaseCount = 0
        let memory = DatabaseMigrationMemoryOperations(
            allocate: { byteCount in
                let pointer = UnsafeMutableRawPointer.allocate(
                    byteCount: max(1, byteCount),
                    alignment: MemoryLayout<UInt8>.alignment
                )
                allocated = pointer
                return pointer
            },
            deserialize: { _, _, _, _, _ in SQLITE_ERROR },
            release: { _ in callerReleaseCount += 1 }
        )

        XCTAssertThrowsError(try DatabaseMigrator(
            connection: connection,
            backupDirectory: backups,
            migrations: Migrations.all,
            backupName: { _ in
                "ledger-v1-100-00000000-0000-4000-8000-000000000000.sqlite"
            },
            memoryOperations: memory
        ).migrate())

        XCTAssertEqual(callerReleaseCount, 0)
        allocated?.deallocate()
        XCTAssertEqual(try connection.userVersion, 1)
        XCTAssertEqual(
            try connection.queryStrings(
                "SELECT name FROM sqlite_master WHERE name = 'daily_usage_quantity_integer_insert';"
            ),
            []
        )
    }

    func testNewerInvalidBackupLookalikesArePreservedAndCannotEvictValidBackups() async throws {
        let directory = try temporaryDirectory()
        let database = directory.appending(path: "ledger.sqlite")
        let backups = directory.appending(path: "Backups")
        let connection = try SQLiteConnection(url: database)
        try DatabaseMigrator(
            connection: connection,
            backupDirectory: backups,
            migrations: [Migrations.v1]
        ).migrate()
        try FileManager.default.createDirectory(at: backups, withIntermediateDirectories: true)
        let validBytes = try validV1BackupBytes()
        let validOld = backups.appending(path: "ledger-v1-100.sqlite")
        let validNew = backups.appending(path: "ledger-v1-200.sqlite")
        try validBytes.write(to: validOld)
        try validBytes.write(to: validNew)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 100)],
            ofItemAtPath: validOld.path
        )
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 200)],
            ofItemAtPath: validNew.path
        )
        let invalidLegacy = backups.appending(path: "ledger-v1-300.sqlite")
        let invalidCanonical = backups.appending(
            path: "ledger-v1-400-00000000-0000-4000-8000-000000000001.sqlite"
        )
        let invalidLegacyBytes = Data("not-a-database-legacy".utf8)
        let metadataForgedBytes = try metadataOnlyV1BackupBytes()
        try invalidLegacyBytes.write(to: invalidLegacy)
        try metadataForgedBytes.write(to: invalidCanonical)
        for invalid in [invalidLegacy, invalidCanonical] {
            try FileManager.default.setAttributes(
                [.modificationDate: Date(timeIntervalSince1970: 4_000_000_000)],
                ofItemAtPath: invalid.path
            )
        }
        let createdName = "ledger-v1-500-00000000-0000-4000-8000-000000000002.sqlite"

        try DatabaseMigrator(
            connection: connection,
            backupDirectory: backups,
            migrations: Migrations.all,
            backupName: { _ in createdName }
        ).migrate()

        let names = try Set(FileManager.default.contentsOfDirectory(atPath: backups.path))
        XCTAssertTrue(names.contains(createdName))
        XCTAssertTrue(names.contains(validNew.lastPathComponent))
        XCTAssertFalse(names.contains(validOld.lastPathComponent))
        XCTAssertTrue(names.contains(invalidLegacy.lastPathComponent))
        XCTAssertTrue(names.contains(invalidCanonical.lastPathComponent))
        XCTAssertEqual(try Data(contentsOf: invalidLegacy), invalidLegacyBytes)
        XCTAssertEqual(try Data(contentsOf: invalidCanonical), metadataForgedBytes)
        let available = try await DatabaseRecoveryService(
            databaseURL: database,
            backupDirectory: backups
        ).availableBackups()
        XCTAssertEqual(Set(available.map(\.filename)), Set([createdName, validNew.lastPathComponent]))
    }

    func testBackupArtifactValidationRejectsContentMutationWithRestoredMetadata() throws {
        let directory = try temporaryDirectory()
        let backup = directory.appending(path: "ledger-v1-100.sqlite")
        try validV1BackupBytes().write(to: backup)
        let descriptor = open(backup.path, O_RDWR | O_CLOEXEC | O_NOFOLLOW)
        XCTAssertTrue(descriptor >= 0)
        defer { if descriptor >= 0 { Darwin.close(descriptor) } }
        var original = stat()
        XCTAssertEqual(fstat(descriptor, &original), 0)

        XCTAssertThrowsError(try DatabaseBackupArtifact.validate(
            descriptor: descriptor,
            maximumBytes: DatabaseRecoveryService.maximumRecoveryImageBytes,
            migrations: Migrations.all,
            afterDatabaseValidation: {
                var byte: UInt8 = 0
                XCTAssertEqual(pread(descriptor, &byte, 1, 100), 1)
                byte ^= 0xff
                XCTAssertEqual(pwrite(descriptor, &byte, 1, 100), 1)
                XCTAssertEqual(fsync(descriptor), 0)
                var timestamps = [original.st_atimespec, original.st_mtimespec]
                XCTAssertEqual(futimens(descriptor, &timestamps), 0)
            }
        ))
    }

    func testBackupArtifactValidationRejectsABAContentSwapAroundDatabaseValidation() throws {
        let directory = try temporaryDirectory()
        let backup = directory.appending(path: "ledger-v1-100.sqlite")
        let validBytes = try validV1BackupBytes()
        var invalidBytes = validBytes
        invalidBytes[100] ^= 0xff
        try invalidBytes.write(to: backup)
        let descriptor = open(backup.path, O_RDWR | O_CLOEXEC | O_NOFOLLOW)
        XCTAssertTrue(descriptor >= 0)
        defer { if descriptor >= 0 { Darwin.close(descriptor) } }
        var original = stat()
        XCTAssertEqual(fstat(descriptor, &original), 0)

        XCTAssertThrowsError(try DatabaseBackupArtifact.validate(
            descriptor: descriptor,
            maximumBytes: DatabaseRecoveryService.maximumRecoveryImageBytes,
            migrations: Migrations.all,
            afterSnapshotCapture: {
                try self.overwrite(descriptor: descriptor, with: validBytes)
            },
            afterDatabaseValidation: {
                try self.overwrite(descriptor: descriptor, with: invalidBytes)
                var timestamps = [original.st_atimespec, original.st_mtimespec]
                XCTAssertEqual(futimens(descriptor, &timestamps), 0)
            }
        ))
    }

    func testNewBackupDirectoryEntryIsSyncedBeforeBackupDirectoryUse() throws {
        let directory = try temporaryDirectory()
        let database = directory.appending(path: "ledger.sqlite")
        let backups = directory.appending(path: "Backups")
        let connection = try SQLiteConnection(url: database)
        try DatabaseMigrator(
            connection: connection,
            backupDirectory: backups,
            migrations: [Migrations.v1]
        ).migrate(createPreMigrationBackup: false)
        var operations: [DatabaseMigrationBackupOperation] = []

        try DatabaseMigrator(
            connection: connection,
            backupDirectory: backups,
            migrations: Migrations.all,
            backupName: { _ in
                "ledger-v1-100-00000000-0000-4000-8000-000000000008.sqlite"
            },
            backupOperation: { operations.append($0) }
        ).migrate()

        XCTAssertEqual(operations.first, .didSyncBackupDirectoryEntry)
        XCTAssertTrue(operations.contains(.didOpenBackupDirectory))
    }

    func testExistingBackupDirectoryEntryIsSyncedBeforeBackupDirectoryUse() throws {
        let directory = try temporaryDirectory()
        let database = directory.appending(path: "ledger.sqlite")
        let backups = directory.appending(path: "Backups")
        let connection = try SQLiteConnection(url: database)
        try DatabaseMigrator(
            connection: connection,
            backupDirectory: backups,
            migrations: [Migrations.v1]
        ).migrate(createPreMigrationBackup: false)
        try FileManager.default.createDirectory(at: backups, withIntermediateDirectories: true)
        var operations: [DatabaseMigrationBackupOperation] = []

        try DatabaseMigrator(
            connection: connection,
            backupDirectory: backups,
            migrations: Migrations.all,
            backupName: { _ in
                "ledger-v1-100-00000000-0000-4000-8000-000000000011.sqlite"
            },
            backupOperation: { operations.append($0) }
        ).migrate()

        XCTAssertEqual(operations.first, .didSyncBackupDirectoryEntry)
        XCTAssertTrue(operations.contains(.didOpenBackupDirectory))
    }

    func testBackupParentRejectsAncestorSymlinkEscape() throws {
        let directory = try temporaryDirectory()
        let escapedRoot = directory.appending(path: "EscapedRoot")
        let escapedSupport = escapedRoot.appending(path: "Support")
        try FileManager.default.createDirectory(
            at: escapedSupport,
            withIntermediateDirectories: true
        )
        let ancestorLink = directory.appending(path: "AncestorLink")
        try FileManager.default.createSymbolicLink(
            at: ancestorLink,
            withDestinationURL: escapedRoot
        )
        let database = ancestorLink.appending(path: "Support/ledger.sqlite")
        let backups = ancestorLink.appending(path: "Support/Backups")
        let connection = try SQLiteConnection(url: database)
        try DatabaseMigrator(
            connection: connection,
            backupDirectory: backups,
            migrations: [Migrations.v1]
        ).migrate()

        XCTAssertThrowsError(try DatabaseMigrator(
            connection: connection,
            backupDirectory: backups,
            migrations: Migrations.all
        ).migrate())

        XCTAssertEqual(try connection.userVersion, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: backups.path))
    }

    func testBackupCreationRejectsExistingRegularSymlinkHardlinkAndFIFOWithoutOverwriting() throws {
        for kind in ["regular", "symlink", "hardlink", "fifo"] {
            let directory = try temporaryDirectory()
            let database = directory.appending(path: "ledger.sqlite")
            let backups = directory.appending(path: "Backups")
            let connection = try SQLiteConnection(url: database)
            try DatabaseMigrator(connection: connection, backupDirectory: backups, migrations: [
                Migration(version: 1, name: "one", sql: "CREATE TABLE one(value INTEGER);")
            ]).migrate()
            try FileManager.default.createDirectory(at: backups, withIntermediateDirectories: true)
            let fixedName = "ledger-v1-100-00000000-0000-4000-8000-000000000000.sqlite"
            let target = backups.appending(path: fixedName)
            let outside = directory.appending(path: "outside")
            try Data("outside".utf8).write(to: outside)
            switch kind {
            case "regular": try Data("sentinel".utf8).write(to: target)
            case "symlink": try FileManager.default.createSymbolicLink(at: target, withDestinationURL: outside)
            case "hardlink": try FileManager.default.linkItem(at: outside, to: target)
            default: XCTAssertEqual(mkfifo(target.path, S_IRUSR | S_IWUSR), 0)
            }

            let migrator = DatabaseMigrator(
                connection: connection,
                backupDirectory: backups,
                migrations: [
                    Migration(version: 1, name: "one", sql: "CREATE TABLE one(value INTEGER);"),
                    Migration(version: 2, name: "two", sql: "CREATE TABLE two(value INTEGER);")
                ],
                backupName: { _ in fixedName }
            )
            XCTAssertThrowsError(try migrator.migrate(), "accepted \(kind)")
            XCTAssertEqual(try Data(contentsOf: outside), Data("outside".utf8))
            if kind == "regular" {
                XCTAssertEqual(try Data(contentsOf: target), Data("sentinel".utf8))
            }
            XCTAssertEqual(try connection.userVersion, 1)
        }
    }

    func testRetentionIgnoresValidLookingSymlinkHardlinkAndFIFO() throws {
        let directory = try temporaryDirectory()
        let database = directory.appending(path: "ledger.sqlite")
        let backups = directory.appending(path: "Backups")
        let connection = try SQLiteConnection(url: database)
        try DatabaseMigrator(
            connection: connection,
            backupDirectory: backups,
            migrations: [Migrations.v1]
        ).migrate()
        try FileManager.default.createDirectory(at: backups, withIntermediateDirectories: true)
        let outside = directory.appending(path: "outside")
        try Data("outside".utf8).write(to: outside)
        let symlink = backups.appending(path: "ledger-v1-10.sqlite")
        let hardlink = backups.appending(path: "ledger-v1-11.sqlite")
        let fifo = backups.appending(path: "ledger-v1-12.sqlite")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: outside)
        try FileManager.default.linkItem(at: outside, to: hardlink)
        XCTAssertEqual(mkfifo(fifo.path, S_IRUSR | S_IWUSR), 0)

        try DatabaseMigrator(
            connection: connection,
            backupDirectory: backups,
            migrations: Migrations.all
        ).migrate()

        XCTAssertEqual(try Data(contentsOf: outside), Data("outside".utf8))
        XCTAssertTrue(FileManager.default.fileExists(atPath: symlink.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: hardlink.path))
        var fifoInfo = stat()
        XCTAssertEqual(lstat(fifo.path, &fifoInfo), 0)
        XCTAssertEqual(fifoInfo.st_mode & S_IFMT, S_IFIFO)
    }

    func testBackupDirectoryReplacementFailsBeforeSchemaWriteAndCleansCreatedArtifact() throws {
        let directory = try temporaryDirectory()
        let database = directory.appending(path: "ledger.sqlite")
        let backups = directory.appending(path: "Backups")
        let retained = directory.appending(path: "RetainedBackups")
        let outside = directory.appending(path: "OutsideBackups")
        let connection = try SQLiteConnection(url: database)
        try DatabaseMigrator(
            connection: connection,
            backupDirectory: backups,
            migrations: [Migrations.v1]
        ).migrate()
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let name = "ledger-v1-100-00000000-0000-4000-8000-000000000000.sqlite"
        let migrator = DatabaseMigrator(
            connection: connection,
            backupDirectory: backups,
            migrations: Migrations.all,
            backupName: { _ in name },
            backupOperation: { operation in
                guard operation == .didOpenBackupDirectory else { return }
                try FileManager.default.moveItem(at: backups, to: retained)
                try FileManager.default.createSymbolicLink(at: backups, withDestinationURL: outside)
            }
        )

        XCTAssertThrowsError(try migrator.migrate())

        XCTAssertFalse(FileManager.default.fileExists(atPath: retained.appending(path: name).path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: outside.path), [])
        XCTAssertEqual(try connection.userVersion, 1)
        XCTAssertEqual(
            try connection.queryStrings(
                "SELECT name FROM sqlite_master WHERE name = 'daily_usage_quantity_integer_insert';"
            ),
            []
        )
    }

    func testBackupDirectoryReplacementAfterArtifactValidationFailsBeforeSchemaWrite() throws {
        let directory = try temporaryDirectory()
        let database = directory.appending(path: "ledger.sqlite")
        let backups = directory.appending(path: "Backups")
        let retained = directory.appending(path: "RetainedBackups")
        let replacement = directory.appending(path: "ReplacementBackups")
        let connection = try SQLiteConnection(url: database)
        try DatabaseMigrator(
            connection: connection,
            backupDirectory: backups,
            migrations: [Migrations.v1]
        ).migrate()
        try FileManager.default.createDirectory(at: replacement, withIntermediateDirectories: true)
        let name = "ledger-v1-100-00000000-0000-4000-8000-000000000007.sqlite"

        XCTAssertThrowsError(try DatabaseMigrator(
            connection: connection,
            backupDirectory: backups,
            migrations: Migrations.all,
            backupName: { _ in name },
            backupOperation: { operation in
                guard operation == .didValidateCreatedBackup else { return }
                try FileManager.default.moveItem(at: backups, to: retained)
                try FileManager.default.createSymbolicLink(
                    at: backups,
                    withDestinationURL: replacement
                )
            }
        ).migrate())

        XCTAssertFalse(FileManager.default.fileExists(atPath: retained.appending(path: name).path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: replacement.path), [])
        XCTAssertEqual(try connection.userVersion, 1)
        XCTAssertEqual(
            try connection.queryStrings(
                "SELECT name FROM sqlite_master WHERE name = 'daily_usage_quantity_integer_insert';"
            ),
            []
        )
    }

    func testCreatedBackupReplacementAfterArtifactValidationFailsBeforeSchemaWrite() throws {
        let directory = try temporaryDirectory()
        let database = directory.appending(path: "ledger.sqlite")
        let backups = directory.appending(path: "Backups")
        let connection = try SQLiteConnection(url: database)
        try DatabaseMigrator(
            connection: connection,
            backupDirectory: backups,
            migrations: [Migrations.v1]
        ).migrate()
        let name = "ledger-v1-100-00000000-0000-4000-8000-000000000009.sqlite"
        let renamed = backups.appending(path: "renamed-after-validation.sqlite")
        let replacement = Data("replacement-after-validation".utf8)

        XCTAssertThrowsError(try DatabaseMigrator(
            connection: connection,
            backupDirectory: backups,
            migrations: Migrations.all,
            backupName: { _ in name },
            backupOperation: { operation in
                guard operation == .didValidateCreatedBackup else { return }
                try FileManager.default.moveItem(at: backups.appending(path: name), to: renamed)
                try replacement.write(to: backups.appending(path: name))
            }
        ).migrate())

        XCTAssertFalse(FileManager.default.fileExists(atPath: renamed.path))
        XCTAssertEqual(try Data(contentsOf: backups.appending(path: name)), replacement)
        XCTAssertEqual(try connection.userVersion, 1)
    }

    func testFinalBindingFailureRestoresBothOriginalBackupsAndCleansCreatedBackup() throws {
        let directory = try temporaryDirectory()
        let database = directory.appending(path: "ledger.sqlite")
        let backups = directory.appending(path: "Backups")
        let retained = directory.appending(path: "RetainedBackups")
        let replacement = directory.appending(path: "ReplacementBackups")
        let connection = try SQLiteConnection(url: database)
        try DatabaseMigrator(
            connection: connection,
            backupDirectory: backups,
            migrations: [Migrations.v1]
        ).migrate()
        try FileManager.default.createDirectory(at: backups, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: replacement, withIntermediateDirectories: true)
        let validBytes = try validV1BackupBytes()
        let originalNames = ["ledger-v1-100.sqlite", "ledger-v1-200.sqlite"]
        for (index, originalName) in originalNames.enumerated() {
            let original = backups.appending(path: originalName)
            try validBytes.write(to: original)
            try FileManager.default.setAttributes(
                [.modificationDate: Date(timeIntervalSince1970: TimeInterval(100 + index))],
                ofItemAtPath: original.path
            )
        }
        let createdName = "ledger-v1-300-00000000-0000-4000-8000-000000000012.sqlite"

        XCTAssertThrowsError(try DatabaseMigrator(
            connection: connection,
            backupDirectory: backups,
            migrations: Migrations.all,
            backupName: { _ in createdName },
            backupOperation: { operation in
                guard operation == .didValidateCreatedBackup else { return }
                try FileManager.default.moveItem(at: backups, to: retained)
                try FileManager.default.createSymbolicLink(
                    at: backups,
                    withDestinationURL: replacement
                )
            }
        ).migrate())

        XCTAssertEqual(
            Set(try FileManager.default.contentsOfDirectory(atPath: retained.path)),
            Set(originalNames)
        )
        for originalName in originalNames {
            XCTAssertEqual(try Data(contentsOf: retained.appending(path: originalName)), validBytes)
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: replacement.path), [])
        XCTAssertEqual(try connection.userVersion, 1)
    }

    func testBackupParentReplacementFailsBeforeSchemaWriteAndCleansCreatedArtifact() throws {
        let root = try temporaryDirectory()
        let parent = root.appending(path: "CanonicalParent")
        let retainedParent = root.appending(path: "RetainedParent")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let database = parent.appending(path: "ledger.sqlite")
        let backups = parent.appending(path: "Backups")
        let connection = try SQLiteConnection(url: database)
        try DatabaseMigrator(connection: connection, backupDirectory: backups, migrations: [
            Migration(version: 1, name: "one", sql: "CREATE TABLE one(value INTEGER);")
        ]).migrate()
        let name = "ledger-v1-100-00000000-0000-4000-8000-000000000003.sqlite"
        let migrator = DatabaseMigrator(
            connection: connection,
            backupDirectory: backups,
            migrations: [
                Migration(version: 1, name: "one", sql: "CREATE TABLE one(value INTEGER);"),
                Migration(version: 2, name: "two", sql: "CREATE TABLE two(value INTEGER);")
            ],
            backupName: { _ in name },
            backupOperation: { operation in
                guard operation == .didOpenBackupDirectory else { return }
                try FileManager.default.moveItem(at: parent, to: retainedParent)
                try FileManager.default.createDirectory(
                    at: parent.appending(path: "Backups"),
                    withIntermediateDirectories: true
                )
            }
        )

        XCTAssertThrowsError(try migrator.migrate())

        XCTAssertFalse(FileManager.default.fileExists(
            atPath: retainedParent.appending(path: "Backups/\(name)").path
        ))
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: parent.appending(path: "Backups").path),
            []
        )
        XCTAssertEqual(try connection.userVersion, 1)
        XCTAssertEqual(try connection.queryStrings("SELECT name FROM sqlite_master WHERE name = 'two';"), [])
    }

    func testCreatedBackupNameReplacementFailsBeforeSchemaWriteAndCleansRenamedArtifact() throws {
        let directory = try temporaryDirectory()
        let database = directory.appending(path: "ledger.sqlite")
        let backups = directory.appending(path: "Backups")
        let connection = try SQLiteConnection(url: database)
        try DatabaseMigrator(connection: connection, backupDirectory: backups, migrations: [
            Migration(version: 1, name: "one", sql: "CREATE TABLE one(value INTEGER);")
        ]).migrate()
        let name = "ledger-v1-100-00000000-0000-4000-8000-000000000004.sqlite"
        let renamed = backups.appending(path: "renamed-created.sqlite")
        let replacement = Data("replacement-must-survive".utf8)
        let migrator = DatabaseMigrator(
            connection: connection,
            backupDirectory: backups,
            migrations: [
                Migration(version: 1, name: "one", sql: "CREATE TABLE one(value INTEGER);"),
                Migration(version: 2, name: "two", sql: "CREATE TABLE two(value INTEGER);")
            ],
            backupName: { _ in name },
            backupOperation: { operation in
                guard case .didSerializeBackup = operation else { return }
                try FileManager.default.moveItem(at: backups.appending(path: name), to: renamed)
                try replacement.write(to: backups.appending(path: name))
            }
        )

        XCTAssertThrowsError(try migrator.migrate())

        XCTAssertFalse(FileManager.default.fileExists(atPath: renamed.path))
        XCTAssertEqual(try Data(contentsOf: backups.appending(path: name)), replacement)
        XCTAssertEqual(try connection.userVersion, 1)
        XCTAssertEqual(try connection.queryStrings("SELECT name FROM sqlite_master WHERE name = 'two';"), [])
    }

    func testRetentionRevalidatesCandidateImmediatelyBeforeUnlink() throws {
        let directory = try temporaryDirectory()
        let database = directory.appending(path: "ledger.sqlite")
        let backups = directory.appending(path: "Backups")
        let connection = try SQLiteConnection(url: database)
        try DatabaseMigrator(
            connection: connection,
            backupDirectory: backups,
            migrations: [Migrations.v1]
        ).migrate()
        try FileManager.default.createDirectory(at: backups, withIntermediateDirectories: true)
        let validBytes = try validV1BackupBytes()
        for second in 100...102 {
            let url = backups.appending(path: "ledger-v1-\(second).sqlite")
            try validBytes.write(to: url)
            try FileManager.default.setAttributes(
                [.modificationDate: Date(timeIntervalSince1970: TimeInterval(second))],
                ofItemAtPath: url.path
            )
        }
        let changedName = "ledger-v1-101.sqlite"
        let changedBytes = Data("changed-after-validation".utf8)
        let createdName = "ledger-v1-200-00000000-0000-4000-8000-000000000005.sqlite"
        try DatabaseMigrator(
            connection: connection,
            backupDirectory: backups,
            migrations: Migrations.all,
            backupName: { _ in createdName },
            backupOperation: { operation in
                guard operation == .willPruneBackup(name: changedName) else { return }
                try changedBytes.write(to: backups.appending(path: changedName))
            }
        ).migrate()

        XCTAssertEqual(try Data(contentsOf: backups.appending(path: changedName)), changedBytes)
        XCTAssertTrue(FileManager.default.fileExists(atPath: backups.appending(path: createdName).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: backups.appending(path: "ledger-v1-102.sqlite").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: backups.appending(path: "ledger-v1-100.sqlite").path))
    }

    func testRetentionQuarantinePreservesReplacementIntroducedAtDestructiveBoundary() throws {
        let directory = try temporaryDirectory()
        let database = directory.appending(path: "ledger.sqlite")
        let backups = directory.appending(path: "Backups")
        let connection = try SQLiteConnection(url: database)
        try DatabaseMigrator(
            connection: connection,
            backupDirectory: backups,
            migrations: [Migrations.v1]
        ).migrate()
        try FileManager.default.createDirectory(at: backups, withIntermediateDirectories: true)
        let validBytes = try validV1BackupBytes()
        for second in 100...102 {
            let url = backups.appending(path: "ledger-v1-\(second).sqlite")
            try validBytes.write(to: url)
            try FileManager.default.setAttributes(
                [.modificationDate: Date(timeIntervalSince1970: TimeInterval(second))],
                ofItemAtPath: url.path
            )
        }
        let targetName = "ledger-v1-101.sqlite"
        let preserved = backups.appending(path: "preserved-original.sqlite")
        let replacement = Data("replacement-at-quarantine-boundary".utf8)
        var didRunHook = false

        try DatabaseMigrator(
            connection: connection,
            backupDirectory: backups,
            migrations: Migrations.all,
            backupName: { _ in
                "ledger-v1-200-00000000-0000-4000-8000-000000000010.sqlite"
            },
            backupOperation: { operation in
                guard operation == .willQuarantineBackup(name: targetName) else { return }
                didRunHook = true
                try FileManager.default.moveItem(
                    at: backups.appending(path: targetName),
                    to: preserved
                )
                try replacement.write(to: backups.appending(path: targetName))
            }
        ).migrate()

        XCTAssertTrue(didRunHook)
        XCTAssertEqual(try Data(contentsOf: backups.appending(path: targetName)), replacement)
        XCTAssertEqual(try Data(contentsOf: preserved), validBytes)
    }

    func testBoundedBackupAcceptsExactPageImageAndUsesNoCopySerialization() throws {
        let directory = try temporaryDirectory()
        let database = directory.appending(path: "ledger.sqlite")
        let backups = directory.appending(path: "Backups")
        let connection = try SQLiteConnection(url: database)
        try DatabaseMigrator(connection: connection, backupDirectory: backups, migrations: [
            Migration(version: 1, name: "one", sql: "CREATE TABLE one(value INTEGER);")
        ]).migrate()
        let pageSize = try XCTUnwrap(Int(try XCTUnwrap(
            connection.queryStrings("PRAGMA page_size;").first
        )))
        let pageCount = try XCTUnwrap(Int(try XCTUnwrap(
            connection.queryStrings("PRAGMA page_count;").first
        )))
        let exactLimit = pageSize * pageCount
        var serializedEvidence: (byteCount: Int, usedNoCopy: Bool)?
        let migrator = DatabaseMigrator(
            connection: connection,
            backupDirectory: backups,
            migrations: [
                Migration(version: 1, name: "one", sql: "CREATE TABLE one(value INTEGER);"),
                Migration(version: 2, name: "two", sql: "CREATE TABLE two(value INTEGER);")
            ],
            backupName: { _ in
                "ledger-v1-100-00000000-0000-4000-8000-000000000000.sqlite"
            },
            backupOperation: { operation in
                guard case let .didSerializeBackup(byteCount, usedNoCopy) = operation else { return }
                serializedEvidence = (byteCount, usedNoCopy)
            },
            maximumBackupBytes: exactLimit
        )

        try migrator.migrate()

        XCTAssertEqual(serializedEvidence?.byteCount, exactLimit)
        XCTAssertEqual(serializedEvidence?.usedNoCopy, true)
        XCTAssertEqual(try connection.userVersion, 2)
    }

    func testOversizedBackupFailsBeforeCreatingDirectoryOrApplyingMigration() throws {
        let directory = try temporaryDirectory()
        let database = directory.appending(path: "ledger.sqlite")
        let backups = directory.appending(path: "Backups")
        let connection = try SQLiteConnection(url: database)
        try DatabaseMigrator(connection: connection, backupDirectory: backups, migrations: [
            Migration(version: 1, name: "one", sql: "CREATE TABLE one(value INTEGER);")
        ]).migrate()
        let pageSize = try XCTUnwrap(Int(try XCTUnwrap(
            connection.queryStrings("PRAGMA page_size;").first
        )))
        let pageCount = try XCTUnwrap(Int(try XCTUnwrap(
            connection.queryStrings("PRAGMA page_count;").first
        )))

        XCTAssertThrowsError(try DatabaseMigrator(
            connection: connection,
            backupDirectory: backups,
            migrations: [
                Migration(version: 1, name: "one", sql: "CREATE TABLE one(value INTEGER);"),
                Migration(version: 2, name: "two", sql: "CREATE TABLE two(value INTEGER);")
            ],
            backupName: { _ in
                "ledger-v1-100-00000000-0000-4000-8000-000000000000.sqlite"
            },
            maximumBackupBytes: pageSize * pageCount - 1
        ).migrate())

        XCTAssertFalse(FileManager.default.fileExists(atPath: backups.path))
        XCTAssertEqual(try connection.userVersion, 1)
        XCTAssertEqual(
            try connection.queryStrings("SELECT name FROM sqlite_master WHERE name = 'two';"),
            []
        )
    }

    func testFutureDatabaseVersionAndMissingPersistedMigrationAreRejected() throws {
        let directory = try temporaryDirectory()
        let connection = try SQLiteConnection(url: directory.appending(path: "ledger.sqlite"))
        let backupDirectory = directory.appending(path: "Backups")
        let migrations = [
            Migration(version: 1, name: "one", sql: "CREATE TABLE one(value INTEGER);"),
            Migration(version: 2, name: "two", sql: "CREATE TABLE two(value INTEGER);")
        ]
        try DatabaseMigrator(connection: connection, backupDirectory: backupDirectory, migrations: migrations).migrate()

        try connection.setUserVersion(3)
        XCTAssertThrowsError(try DatabaseMigrator(connection: connection, backupDirectory: backupDirectory, migrations: migrations).migrate())

        try connection.setUserVersion(2)
        try connection.execute("DELETE FROM schema_migrations WHERE version = 2;")
        XCTAssertThrowsError(try DatabaseMigrator(connection: connection, backupDirectory: backupDirectory, migrations: migrations).migrate())
    }

    func testFailedUpgradeRetentionPreservesUnrelatedFiles() throws {
        let directory = try temporaryDirectory()
        let connection = try SQLiteConnection(url: directory.appending(path: "ledger.sqlite"))
        let backupDirectory = directory.appending(path: "Backups")
        try DatabaseMigrator(connection: connection, backupDirectory: backupDirectory, migrations: [
            Migration(version: 1, name: "one", sql: "CREATE TABLE one(value INTEGER);")
        ]).migrate()
        try FileManager.default.createDirectory(at: backupDirectory, withIntermediateDirectories: true)
        for index in 0..<3 {
            let file = backupDirectory.appending(path: "stale-\(index).sqlite")
            FileManager.default.createFile(atPath: file.path, contents: Data())
            try FileManager.default.setAttributes(
                [.modificationDate: Date(timeIntervalSince1970: TimeInterval(index))],
                ofItemAtPath: file.path
            )
        }

        XCTAssertThrowsError(try DatabaseMigrator(connection: connection, backupDirectory: backupDirectory, migrations: [
            Migration(version: 1, name: "one", sql: "CREATE TABLE one(value INTEGER);"),
            Migration(version: 2, name: "invalid", sql: "CREATE TABLE broken(value INTEGER); CREATE TABL invalid(value INTEGER);")
        ]).migrate())
        let names = try FileManager.default.contentsOfDirectory(atPath: backupDirectory.path)
        XCTAssertEqual(names.filter { $0.hasPrefix("stale-") }.count, 3)
        XCTAssertEqual(names.filter { $0.hasPrefix("ledger-v") }.count, 1)
    }

    func testCSQLiteModuleMapUsesPortableShim() throws {
        let moduleMap = try String(contentsOf: TestRepository.root.appending(path: "Sources/CSQLite/module.modulemap"))
        let shim = try String(contentsOf: TestRepository.root.appending(path: "Sources/CSQLite/sqlite_shim.h"))
        XCTAssertTrue(moduleMap.contains("header \"sqlite_shim.h\""))
        XCTAssertTrue(shim.contains("#include <sqlite3.h>"))
    }

    private func validV1BackupBytes() throws -> Data {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = directory.appending(path: "ledger.sqlite")
        let connection = try SQLiteConnection(url: database)
        try DatabaseMigrator(
            connection: connection,
            backupDirectory: directory.appending(path: "Backups"),
            migrations: [Migrations.v1]
        ).migrate(createPreMigrationBackup: false)
        try connection.checkpointWAL()
        try connection.close()
        return try Data(contentsOf: database)
    }

    private func metadataOnlyV1BackupBytes() throws -> Data {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = directory.appending(path: "ledger.sqlite")
        let connection = try SQLiteConnection(url: database)
        try connection.execute("""
        CREATE TABLE schema_migrations(
          version INTEGER PRIMARY KEY,
          name TEXT NOT NULL,
          checksum TEXT NOT NULL,
          applied_at TEXT NOT NULL
        );
        INSERT INTO schema_migrations(version, name, checksum, applied_at)
        VALUES(1, '\(Migrations.v1.name)', '\(databaseMigrationChecksum(Migrations.v1.sql))', 'now');
        PRAGMA user_version = 1;
        """)
        try connection.checkpointWAL()
        try connection.close()
        return try Data(contentsOf: database)
    }

    private func overwrite(descriptor: Int32, with data: Data) throws {
        var offset = 0
        try data.withUnsafeBytes { bytes in
            while offset < data.count {
                let result = pwrite(
                    descriptor,
                    bytes.baseAddress!.advanced(by: offset),
                    data.count - offset,
                    off_t(offset)
                )
                guard result > 0 else {
                    if result < 0, errno == EINTR { continue }
                    throw SQLiteFailure(code: SQLITE_IOERR, message: "test overwrite failed")
                }
                offset += result
            }
        }
        XCTAssertEqual(ftruncate(descriptor, off_t(data.count)), 0)
        XCTAssertEqual(fsync(descriptor), 0)
    }
}

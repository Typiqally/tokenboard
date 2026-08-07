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
        for required in ["app_metadata", "daily_usage", "source_checkpoints", "skipped_records", "price_rates", "model_aliases", "catalog_imports", "schema_migrations"] {
            XCTAssertTrue(names.contains(required), "missing \(required)")
        }
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
        try DatabaseMigrator(connection: connection, backupDirectory: backups, migrations: [
            Migration(version: 1, name: "one", sql: "CREATE TABLE one(value INTEGER);")
        ]).migrate()
        try FileManager.default.createDirectory(at: backups, withIntermediateDirectories: true)
        let unrelated = backups.appending(path: "notes.txt")
        try Data("keep".utf8).write(to: unrelated)
        for second in 100...102 {
            let legacy = backups.appending(path: "ledger-v1-\(second).sqlite")
            try Data("legacy-\(second)".utf8).write(to: legacy)
            try FileManager.default.setAttributes(
                [.modificationDate: Date(timeIntervalSince1970: TimeInterval(second))],
                ofItemAtPath: legacy.path
            )
        }

        try DatabaseMigrator(connection: connection, backupDirectory: backups, migrations: [
            Migration(version: 1, name: "one", sql: "CREATE TABLE one(value INTEGER);"),
            Migration(version: 2, name: "two", sql: "CREATE TABLE two(value INTEGER);")
        ]).migrate()

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
        try DatabaseMigrator(connection: connection, backupDirectory: backups, migrations: [
            Migration(version: 1, name: "one", sql: "CREATE TABLE one(value INTEGER);")
        ]).migrate()
        try FileManager.default.createDirectory(at: backups, withIntermediateDirectories: true)
        let outside = directory.appending(path: "outside")
        try Data("outside".utf8).write(to: outside)
        let symlink = backups.appending(path: "ledger-v1-10.sqlite")
        let hardlink = backups.appending(path: "ledger-v1-11.sqlite")
        let fifo = backups.appending(path: "ledger-v1-12.sqlite")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: outside)
        try FileManager.default.linkItem(at: outside, to: hardlink)
        XCTAssertEqual(mkfifo(fifo.path, S_IRUSR | S_IWUSR), 0)

        try DatabaseMigrator(connection: connection, backupDirectory: backups, migrations: [
            Migration(version: 1, name: "one", sql: "CREATE TABLE one(value INTEGER);"),
            Migration(version: 2, name: "two", sql: "CREATE TABLE two(value INTEGER);")
        ]).migrate()

        XCTAssertEqual(try Data(contentsOf: outside), Data("outside".utf8))
        XCTAssertTrue(FileManager.default.fileExists(atPath: symlink.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: hardlink.path))
        var fifoInfo = stat()
        XCTAssertEqual(lstat(fifo.path, &fifoInfo), 0)
        XCTAssertEqual(fifoInfo.st_mode & S_IFMT, S_IFIFO)
    }

    func testRetainedBackupDirectoryDescriptorDefeatsParentPathReplacement() throws {
        let directory = try temporaryDirectory()
        let database = directory.appending(path: "ledger.sqlite")
        let backups = directory.appending(path: "Backups")
        let retained = directory.appending(path: "RetainedBackups")
        let outside = directory.appending(path: "OutsideBackups")
        let connection = try SQLiteConnection(url: database)
        try DatabaseMigrator(connection: connection, backupDirectory: backups, migrations: [
            Migration(version: 1, name: "one", sql: "CREATE TABLE one(value INTEGER);")
        ]).migrate()
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let name = "ledger-v1-100-00000000-0000-4000-8000-000000000000.sqlite"
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
                try FileManager.default.moveItem(at: backups, to: retained)
                try FileManager.default.createSymbolicLink(at: backups, withDestinationURL: outside)
            }
        )

        try migrator.migrate()

        XCTAssertTrue(FileManager.default.fileExists(atPath: retained.appending(path: name).path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: outside.path), [])
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
}

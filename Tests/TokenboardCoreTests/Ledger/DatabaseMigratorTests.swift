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

    func testFailedUpgradeRetainsOnlyNewestTwoBackups() throws {
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
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: backupDirectory.path).count, 2)
    }

    func testCSQLiteModuleMapUsesPortableShim() throws {
        let moduleMap = try String(contentsOf: TestRepository.root.appending(path: "Sources/CSQLite/module.modulemap"))
        let shim = try String(contentsOf: TestRepository.root.appending(path: "Sources/CSQLite/sqlite_shim.h"))
        XCTAssertTrue(moduleMap.contains("header \"sqlite_shim.h\""))
        XCTAssertTrue(shim.contains("#include <sqlite3.h>"))
    }
}

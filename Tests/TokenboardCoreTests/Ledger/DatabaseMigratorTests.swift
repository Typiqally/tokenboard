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
            Migration(version: 2, name: "invalid", sql: "CREATE TABL broken(value INTEGER);")
        ]
        let migrator = DatabaseMigrator(
            connection: connection,
            backupDirectory: directory.appending(path: "Backups"),
            migrations: migrations
        )
        XCTAssertThrowsError(try migrator.migrate())
        XCTAssertFalse(try connection.queryStrings("SELECT name FROM sqlite_master").contains("broken"))
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
}

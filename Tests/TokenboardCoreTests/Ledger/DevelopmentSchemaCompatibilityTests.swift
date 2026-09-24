import Foundation
import XCTest
@testable import TokenboardCore

final class DevelopmentSchemaCompatibilityTests: XCTestCase {
    func testReopensDevelopmentV7WithoutChangingUsagePricesOrActivity() async throws {
        let root = canonicalTestTemporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let database = root.appending(path: "ledger.sqlite")
        let backups = root.appending(path: "Backups")
        let connection = try SQLiteConnection(url: database)
        // Pin the migration shipped in the development build independently of
        // Migrations.all: changing its SQL would invalidate persisted checksums.
        let v7 = Migration(
            version: 7,
            name: "store daily agent activity counters",
            sql: """
            CREATE TABLE daily_agent_activity(
              local_day TEXT NOT NULL,
              time_zone TEXT NOT NULL,
              provider TEXT NOT NULL,
              observed_model_id TEXT NOT NULL,
              counter TEXT NOT NULL,
              quantity INTEGER NOT NULL CHECK(typeof(quantity) = 'integer' AND quantity >= 0),
              PRIMARY KEY(local_day, time_zone, provider, observed_model_id, counter)
            );
            CREATE INDEX daily_agent_activity_day_idx
              ON daily_agent_activity(local_day, provider);
            ALTER TABLE source_checkpoints
              ADD COLUMN agent_activity_counted_from_offset INTEGER NOT NULL DEFAULT 0
              CHECK(typeof(agent_activity_counted_from_offset) = 'integer'
                    AND agent_activity_counted_from_offset >= 0);
            UPDATE source_checkpoints SET agent_activity_counted_from_offset = byte_offset;
            """
        )

        try DatabaseMigrator(
            connection: connection, backupDirectory: backups,
            migrations: Array(Migrations.all.prefix(6)) + [v7]
        ).migrate()
        try connection.execute("""
        INSERT INTO daily_usage VALUES(
          '2026-08-01', 'Europe/Amsterdam', 'codex', 'gpt-test',
          'input_uncached', 'additive', 17
        );
        INSERT INTO price_rates VALUES(
          'codex', 'gpt-test', 'input_uncached', '5', '2026-01-01', NULL,
          'https://openai.com/api/pricing/', '2026-08-01', 'synthetic-catalog'
        );
        INSERT INTO daily_agent_activity VALUES(
          '2026-08-01', 'Europe/Amsterdam', 'codex', 'gpt-test', 'tasks', 3
        );
        INSERT INTO source_checkpoints VALUES(
          '\(String(repeating: "a", count: 64))', 'codex', 1, 4096, 4096, NULL,
          NULL, NULL, '{}', '{}', 2048
        );
        """)
        try connection.close()

        let ledger = try SQLiteLedger(databaseURL: database, backupDirectory: backups)
        try await ledger.migrate()
        try await ledger.integrityCheck()
        try await ledger.shutdown()

        let reopened = try SQLiteConnection(url: database)
        defer { try? reopened.close() }
        XCTAssertEqual(try reopened.userVersion, 7)
        XCTAssertEqual(try reopened.queryStrings("SELECT quantity FROM daily_usage;"), ["17"])
        XCTAssertEqual(try reopened.queryStrings("SELECT usd_per_million FROM price_rates;"), ["5"])
        XCTAssertEqual(try reopened.queryStrings("SELECT quantity FROM daily_agent_activity;"), ["3"])
        XCTAssertEqual(try reopened.queryStrings(
            "SELECT byte_offset || ':' || agent_activity_counted_from_offset FROM source_checkpoints;"
        ), ["4096:2048"])
    }
}

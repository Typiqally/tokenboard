import CSQLite
import CryptoKit
import Foundation

public struct Migration: Sendable {
    public let version: Int32
    public let name: String
    public let sql: String

    public init(version: Int32, name: String, sql: String) {
        self.version = version
        self.name = name
        self.sql = sql
    }
}

public struct DatabaseMigrator {
    let connection: SQLiteConnection
    let backupDirectory: URL
    let migrations: [Migration]

    public init(connection: SQLiteConnection, backupDirectory: URL, migrations: [Migration]) {
        self.connection = connection
        self.backupDirectory = backupDirectory
        self.migrations = migrations
    }

    public func migrate() throws {
        try connection.execute("CREATE TABLE IF NOT EXISTS schema_migrations(version INTEGER PRIMARY KEY, name TEXT NOT NULL, checksum TEXT NOT NULL, applied_at TEXT NOT NULL);")
        try verifyAppliedMigrationChecksums()

        let pending = migrations
            .filter { $0.version > connection.userVersion }
            .sorted { $0.version < $1.version }
        if connection.userVersion > 0, !pending.isEmpty {
            try createBackup()
        }

        for migration in pending {
            try connection.transaction {
                try connection.execute(migration.sql)
                let escapedName = migration.name.replacingOccurrences(of: "'", with: "''")
                try connection.execute(
                    "INSERT INTO schema_migrations VALUES(\(migration.version), '\(escapedName)', '\(checksum(for: migration.sql))', '\(ISO8601DateFormatter().string(from: Date()))');"
                )
                try connection.setUserVersion(migration.version)
            }
        }

        try retainNewestTwoBackups()
    }

    private func verifyAppliedMigrationChecksums() throws {
        for migration in migrations where migration.version <= connection.userVersion {
            let rows = try connection.queryStrings(
                "SELECT checksum FROM schema_migrations WHERE version = \(migration.version);"
            )
            guard rows == [checksum(for: migration.sql)] else {
                throw SQLiteFailure(
                    code: SQLITE_CORRUPT,
                    message: "migration checksum mismatch at version \(migration.version)"
                )
            }
        }
    }

    private func createBackup() throws {
        try FileManager.default.createDirectory(at: backupDirectory, withIntermediateDirectories: true)
        let target = backupDirectory.appending(
            path: "ledger-v\(connection.userVersion)-\(Int(Date().timeIntervalSince1970)).sqlite"
        )
        var destination: OpaquePointer?
        let openResult = sqlite3_open(target.path, &destination)
        guard openResult == SQLITE_OK, let destination else {
            if let destination {
                sqlite3_close(destination)
            }
            throw SQLiteFailure(code: openResult, message: "unable to create migration backup")
        }
        defer {
            sqlite3_close(destination)
        }

        guard let backup = sqlite3_backup_init(destination, "main", connection.handle, "main") else {
            throw SQLiteFailure(code: sqlite3_errcode(destination), message: String(cString: sqlite3_errmsg(destination)))
        }
        defer {
            sqlite3_backup_finish(backup)
        }

        guard sqlite3_backup_step(backup, -1) == SQLITE_DONE else {
            throw SQLiteFailure(code: sqlite3_errcode(destination), message: String(cString: sqlite3_errmsg(destination)))
        }
    }

    private func retainNewestTwoBackups() throws {
        guard FileManager.default.fileExists(atPath: backupDirectory.path) else {
            return
        }
        let files = try FileManager.default.contentsOfDirectory(
            at: backupDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey]
        ).sorted {
            let left = try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            let right = try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            return (left ?? .distantPast) > (right ?? .distantPast)
        }
        for stale in files.dropFirst(2) {
            try FileManager.default.removeItem(at: stale)
        }
    }

    private func checksum(for sql: String) -> String {
        SHA256.hash(data: Data(sql.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

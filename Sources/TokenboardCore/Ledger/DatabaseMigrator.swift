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
        let currentVersion = try connection.userVersion
        try validateMigrationDefinitions()
        try verifyAppliedMigrationState(upTo: currentVersion)

        let pending = migrations
            .filter { $0.version > currentVersion }
            .sorted { $0.version < $1.version }
        if currentVersion > 0, !pending.isEmpty {
            try createBackup()
            try retainNewestTwoBackups()
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

    }

    private func validateMigrationDefinitions() throws {
        let versions = migrations.map(\.version).sorted()
        for (offset, version) in versions.enumerated() where version != Int32(offset + 1) {
            throw SQLiteFailure(code: SQLITE_CORRUPT, message: "migration versions must be unique and contiguous from 1")
        }
    }

    private func verifyAppliedMigrationState(upTo currentVersion: Int32) throws {
        guard currentVersion >= 0 else {
            throw SQLiteFailure(code: SQLITE_CORRUPT, message: "invalid user_version")
        }
        guard currentVersion <= Int32(migrations.count) else {
            throw SQLiteFailure(code: SQLITE_CORRUPT, message: "database schema is newer than this application")
        }

        let appliedVersions = try connection.queryStrings(
            "SELECT version FROM schema_migrations ORDER BY version;"
        ).compactMap(Int32.init)
        let expectedVersions: [Int32] = currentVersion == 0
            ? []
            : (1...currentVersion).map { $0 }
        guard appliedVersions == expectedVersions else {
            throw SQLiteFailure(code: SQLITE_CORRUPT, message: "persisted migration versions do not match user_version")
        }

        for migration in migrations where migration.version <= currentVersion {
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
            path: "ledger-v\(try connection.userVersion)-\(Int(Date().timeIntervalSince1970)).sqlite"
        )
        var completed = false
        defer {
            if !completed {
                try? FileManager.default.removeItem(at: target)
            }
        }

        var destination: OpaquePointer?
        let openResult = sqlite3_open(target.path, &destination)
        guard openResult == SQLITE_OK, let destination else {
            if let destination {
                sqlite3_close(destination)
            }
            throw SQLiteFailure(code: openResult, message: "unable to create migration backup")
        }

        guard let backup = sqlite3_backup_init(destination, "main", connection.handle, "main") else {
            let backupCode = sqlite3_errcode(destination)
            let message = String(cString: sqlite3_errmsg(destination))
            let closeResult = sqlite3_close(destination)
            guard closeResult == SQLITE_OK else {
                throw SQLiteFailure(code: closeResult, message: "unable to close failed migration backup")
            }
            throw SQLiteFailure(code: backupCode, message: message)
        }

        let stepResult = sqlite3_backup_step(backup, -1)
        let finishResult = sqlite3_backup_finish(backup)
        let closeResult = sqlite3_close(destination)
        guard stepResult == SQLITE_DONE else {
            throw SQLiteFailure(code: stepResult, message: "unable to complete migration backup")
        }
        guard finishResult == SQLITE_OK else {
            throw SQLiteFailure(code: finishResult, message: "unable to finalize migration backup")
        }
        guard closeResult == SQLITE_OK else {
            throw SQLiteFailure(code: closeResult, message: "unable to close migration backup")
        }
        completed = true
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

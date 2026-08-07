import CSQLite
import CryptoKit
import Darwin
import Foundation

enum DatabaseBackupArtifactError: Error, Equatable {
    case unsafe
    case tooLarge
}

struct DatabaseBackupArtifactIdentity: Equatable {
    let device: UInt64
    let inode: UInt64
    let size: Int64
    let modificationSeconds: Int64
    let modificationNanoseconds: Int64
    let digest: String

    init(information: stat, digest: String) {
        device = UInt64(information.st_dev)
        inode = UInt64(information.st_ino)
        size = Int64(information.st_size)
        modificationSeconds = Int64(information.st_mtimespec.tv_sec)
        modificationNanoseconds = Int64(information.st_mtimespec.tv_nsec)
        self.digest = digest
    }

    func binds(_ information: stat) -> Bool {
        information.st_mode & S_IFMT == S_IFREG
            && information.st_nlink == 1
            && UInt64(information.st_dev) == device
            && UInt64(information.st_ino) == inode
            && Int64(information.st_size) == size
            && Int64(information.st_mtimespec.tv_sec) == modificationSeconds
            && Int64(information.st_mtimespec.tv_nsec) == modificationNanoseconds
    }
}

enum DatabaseBackupArtifact {
    static func validate(
        descriptor: Int32,
        maximumBytes: Int,
        migrations: [Migration],
        afterSnapshotCapture: () throws -> Void = {},
        afterDatabaseValidation: () throws -> Void = {}
    ) throws -> DatabaseBackupArtifactIdentity {
        var before = stat()
        guard fstat(descriptor, &before) == 0,
              before.st_mode & S_IFMT == S_IFREG,
              before.st_nlink == 1,
              before.st_size >= 20 else {
            throw DatabaseBackupArtifactError.unsafe
        }
        guard before.st_size <= Int64(maximumBytes) else {
            throw DatabaseBackupArtifactError.tooLarge
        }
        let (allocatedBytes, overflowed) = Int64(before.st_blocks).multipliedReportingOverflow(by: 512)
        guard !overflowed, allocatedBytes >= before.st_size else {
            throw DatabaseBackupArtifactError.unsafe
        }
        guard let byteCount = Int(exactly: before.st_size) else {
            throw DatabaseBackupArtifactError.tooLarge
        }
        let captured = try SQLiteConnection.capturedRecoveryConnection(
            descriptor: descriptor,
            byteCount: byteCount,
            maximumBytes: maximumBytes
        )
        try afterSnapshotCapture()

        let connection = captured.connection
        do {
            let quickCheck = try connection.queryStrings("PRAGMA quick_check;")
            guard quickCheck == ["ok"] else {
                throw DatabaseBackupArtifactError.unsafe
            }
            try validateSupportedSchema(connection: connection, migrations: migrations)
            try connection.close()
            try afterDatabaseValidation()
        } catch {
            try? connection.close()
            throw error
        }

        let digest = try digest(of: descriptor)
        var after = stat()
        guard fstat(descriptor, &after) == 0,
              sameMetadata(before, after),
              digest == captured.digest else {
            throw DatabaseBackupArtifactError.unsafe
        }
        return DatabaseBackupArtifactIdentity(information: after, digest: digest)
    }

    private static func validateSupportedSchema(
        connection: SQLiteConnection,
        migrations: [Migration]
    ) throws {
        let version = try connection.userVersion
        guard version > 0, version <= Int32(migrations.count) else {
            throw DatabaseBackupArtifactError.unsafe
        }
        let tables = try connection.queryStrings(
            "SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'schema_migrations';"
        )
        guard tables == ["schema_migrations"] else {
            throw DatabaseBackupArtifactError.unsafe
        }
        let persistedVersions = try connection.queryStrings(
            "SELECT version FROM schema_migrations ORDER BY version;"
        )
        let versions = persistedVersions.compactMap(Int32.init)
        guard persistedVersions.count == Int(version),
              versions.count == persistedVersions.count,
              versions == (1...version).map({ $0 }) else {
            throw DatabaseBackupArtifactError.unsafe
        }
        for migration in migrations where migration.version <= version {
            guard try connection.queryStrings(
                "SELECT name FROM schema_migrations WHERE version = \(migration.version);"
            ) == [migration.name],
            try connection.queryStrings(
                "SELECT checksum FROM schema_migrations WHERE version = \(migration.version);"
            ) == [databaseMigrationChecksum(migration.sql)] else {
                throw DatabaseBackupArtifactError.unsafe
            }
        }
        guard try schemaManifest(connection) == expectedSchemaManifest(
            through: version,
            migrations: migrations
        ) else {
            throw DatabaseBackupArtifactError.unsafe
        }
    }

    private static func expectedSchemaManifest(
        through version: Int32,
        migrations: [Migration]
    ) throws -> [String] {
        let expected = try SQLiteConnection.transient()
        do {
            try expected.execute(databaseSchemaMigrationsSQL)
            for migration in migrations
                .filter({ $0.version <= version })
                .sorted(by: { $0.version < $1.version }) {
                try expected.execute(migration.sql)
            }
            let manifest = try schemaManifest(expected)
            try expected.close()
            return manifest
        } catch {
            try? expected.close()
            throw error
        }
    }

    private static func schemaManifest(_ connection: SQLiteConnection) throws -> [String] {
        try connection.queryStrings("""
        SELECT type || ':' || hex(name) || ':' || hex(tbl_name) || ':' || hex(COALESCE(sql, ''))
        FROM sqlite_master
        WHERE name NOT LIKE 'sqlite_%'
        ORDER BY type, name, tbl_name, sql;
        """)
    }

    private static func digest(of descriptor: Int32) throws -> String {
        var hasher = SHA256()
        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        var offset: off_t = 0
        while true {
            let count = pread(descriptor, &buffer, buffer.count, offset)
            if count == 0 { break }
            guard count > 0 else {
                if errno == EINTR { continue }
                throw DatabaseBackupArtifactError.unsafe
            }
            hasher.update(data: Data(buffer[0..<count]))
            offset += off_t(count)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func sameMetadata(_ lhs: stat, _ rhs: stat) -> Bool {
        lhs.st_dev == rhs.st_dev
            && lhs.st_ino == rhs.st_ino
            && lhs.st_mode == rhs.st_mode
            && lhs.st_nlink == rhs.st_nlink
            && lhs.st_size == rhs.st_size
            && lhs.st_mtimespec.tv_sec == rhs.st_mtimespec.tv_sec
            && lhs.st_mtimespec.tv_nsec == rhs.st_mtimespec.tv_nsec
    }
}

func databaseMigrationChecksum(_ sql: String) -> String {
    SHA256.hash(data: Data(sql.utf8)).map { String(format: "%02x", $0) }.joined()
}

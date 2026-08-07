import CSQLite
import CryptoKit
import Darwin
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

enum DatabaseMigrationBackupOperation: Equatable {
    case didOpenBackupDirectory
    case didSerializeBackup(byteCount: Int, usedNoCopy: Bool)
}

enum DatabaseBackupNaming {
    private static let pattern = try! NSRegularExpression(
        pattern: #"^ledger-v[0-9]+-[0-9]+(?:-[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12})?\.sqlite$"#
    )

    static func canonical(version: Int32) -> String {
        let timestamp = Int64(Date().timeIntervalSince1970)
        return "ledger-v\(version)-\(timestamp)-\(UUID().uuidString.lowercased()).sqlite"
    }

    static func isBackupFilename(_ filename: String) -> Bool {
        let range = NSRange(filename.startIndex..<filename.endIndex, in: filename)
        return pattern.firstMatch(in: filename, range: range)?.range == range
    }
}

public struct DatabaseMigrator {
    let connection: SQLiteConnection
    let backupDirectory: URL
    let migrations: [Migration]
    private let backupName: (Int32) -> String
    private let backupOperation: (DatabaseMigrationBackupOperation) throws -> Void
    private let maximumBackupBytes: Int

    public init(connection: SQLiteConnection, backupDirectory: URL, migrations: [Migration]) {
        self.connection = connection
        self.backupDirectory = backupDirectory
        self.migrations = migrations
        backupName = DatabaseBackupNaming.canonical
        backupOperation = { _ in }
        maximumBackupBytes = DatabaseRecoveryService.maximumRecoveryImageBytes
    }

    init(
        connection: SQLiteConnection,
        backupDirectory: URL,
        migrations: [Migration],
        backupName: @escaping (Int32) -> String,
        backupOperation: @escaping (DatabaseMigrationBackupOperation) throws -> Void = { _ in },
        maximumBackupBytes: Int = DatabaseRecoveryService.maximumRecoveryImageBytes
    ) {
        self.connection = connection
        self.backupDirectory = backupDirectory
        self.migrations = migrations
        self.backupName = backupName
        self.backupOperation = backupOperation
        self.maximumBackupBytes = maximumBackupBytes
    }

    public func migrate(createPreMigrationBackup: Bool = true) throws {
        try validateMigrationDefinitions()
        let currentVersion = try connection.userVersion
        try preflightDatabase(upTo: currentVersion)

        let pending = migrations
            .filter { $0.version > currentVersion }
            .sorted { $0.version < $1.version }
        if createPreMigrationBackup, currentVersion > 0, !pending.isEmpty {
            let layout = try validatedBackupLayout()
            try withBackupDirectory { directory in
                try createBackup(in: directory, version: currentVersion, layout: layout)
                try retainNewestTwoBackups(in: directory)
            }
        }

        for migration in pending {
            try connection.transaction {
                if currentVersion == 0, migration.version == 1 {
                    try connection.execute(Self.schemaMigrationsSQL)
                }
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
            throw corrupt("migration versions must be unique and contiguous from 1")
        }
    }

    private func preflightDatabase(upTo currentVersion: Int32) throws {
        guard currentVersion >= 0 else { throw corrupt("invalid user_version") }
        guard currentVersion <= Int32(migrations.count) else {
            throw corrupt("database schema is newer than this application")
        }

        let userTables = try connection.queryStrings(
            "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%' ORDER BY name;"
        )
        if currentVersion == 0 {
            guard userTables.isEmpty else {
                throw corrupt("version zero database contains an untracked schema")
            }
            return
        }
        guard userTables.contains("schema_migrations") else {
            throw corrupt("schema_migrations is missing")
        }

        let appliedVersions = try connection.queryStrings(
            "SELECT version FROM schema_migrations ORDER BY version;"
        ).compactMap(Int32.init)
        let expectedVersions = (1...currentVersion).map { $0 }
        guard appliedVersions == expectedVersions else {
            throw corrupt("persisted migration versions do not match user_version")
        }

        for migration in migrations where migration.version <= currentVersion {
            let names = try connection.queryStrings(
                "SELECT name FROM schema_migrations WHERE version = \(migration.version);"
            )
            guard names == [migration.name] else {
                throw corrupt("migration name mismatch at version \(migration.version)")
            }
            let checksums = try connection.queryStrings(
                "SELECT checksum FROM schema_migrations WHERE version = \(migration.version);"
            )
            guard checksums == [checksum(for: migration.sql)] else {
                throw corrupt("migration checksum mismatch at version \(migration.version)")
            }
        }
    }

    private func withBackupDirectory(_ body: (Int32) throws -> Void) throws {
        let standardized = backupDirectory.standardizedFileURL
        guard backupDirectory.isFileURL,
              backupDirectory.path == standardized.path,
              isSinglePathComponent(standardized.lastPathComponent) else {
            throw failure(SQLITE_CANTOPEN, "invalid migration backup directory")
        }
        let parentPath = standardized.deletingLastPathComponent().path
        let parent = Darwin.open(
            parentPath,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        )
        guard parent >= 0 else { throw posixFailure("unable to open migration backup parent") }
        defer { Darwin.close(parent) }

        let name = standardized.lastPathComponent
        if mkdirat(parent, name, S_IRWXU) != 0, errno != EEXIST {
            throw posixFailure("unable to create migration backup directory")
        }
        let directory = openat(
            parent,
            name,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        )
        guard directory >= 0 else { throw posixFailure("unable to open migration backup directory") }
        defer { Darwin.close(directory) }
        var information = stat()
        guard fstat(directory, &information) == 0,
              information.st_mode & S_IFMT == S_IFDIR else {
            throw failure(SQLITE_CANTOPEN, "unsafe migration backup directory")
        }
        try backupOperation(.didOpenBackupDirectory)
        try body(directory)
    }

    private func validatedBackupLayout() throws -> BackupLayout {
        let pageSizes = try connection.queryStrings("PRAGMA page_size;")
        let pageCounts = try connection.queryStrings("PRAGMA page_count;")
        guard pageSizes.count == 1,
              pageCounts.count == 1,
              let pageSize = Int64(pageSizes[0]),
              let pageCount = Int64(pageCounts[0]),
              pageSize > 0,
              pageCount > 0 else {
            throw corrupt("migration backup page layout is invalid")
        }
        let (byteCount, overflowed) = pageSize.multipliedReportingOverflow(by: pageCount)
        guard !overflowed,
              byteCount <= Int64(maximumBackupBytes),
              let capacity = Int(exactly: byteCount) else {
            throw failure(SQLITE_TOOBIG, "migration backup exceeds the recovery support limit")
        }
        return BackupLayout(pageSize: pageSize, byteCount: capacity)
    }

    private func createBackup(
        in directory: Int32,
        version: Int32,
        layout: BackupLayout
    ) throws {
        let name = backupName(version)
        guard DatabaseBackupNaming.isBackupFilename(name), isSinglePathComponent(name) else {
            throw failure(SQLITE_CANTOPEN, "invalid migration backup name")
        }
        let descriptor = openat(
            directory,
            name,
            O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else { throw posixFailure("unable to create migration backup") }
        var completed = false
        defer {
            if !completed { unlinkCreatedFile(descriptor, in: directory, name: name) }
            Darwin.close(descriptor)
        }

        var destination: OpaquePointer?
        let openResult = sqlite3_open_v2(
            ":memory:",
            &destination,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX,
            nil
        )
        guard openResult == SQLITE_OK, let destination else {
            if let destination { sqlite3_close(destination) }
            throw failure(openResult, "unable to open bounded migration backup image")
        }
        var destinationOpen = true
        defer {
            if destinationOpen { sqlite3_close(destination) }
        }
        guard let storage = sqlite3_malloc64(sqlite3_uint64(layout.byteCount)) else {
            throw failure(SQLITE_NOMEM, "unable to allocate bounded migration backup image")
        }
        let deserializeResult = sqlite3_deserialize(
            destination,
            "main",
            storage,
            0,
            sqlite3_int64(layout.byteCount),
            UInt32(SQLITE_DESERIALIZE_FREEONCLOSE)
        )
        guard deserializeResult == SQLITE_OK else {
            sqlite3_free(storage)
            throw failure(deserializeResult, "unable to initialize bounded migration backup image")
        }
        let maximumPages = max(1, Int64(maximumBackupBytes) / layout.pageSize)
        guard sqlite3_exec(
            destination,
            "PRAGMA page_size = \(layout.pageSize); PRAGMA max_page_count = \(maximumPages);",
            nil,
            nil,
            nil
        ) == SQLITE_OK else {
            throw failure(sqlite3_errcode(destination), "unable to bound migration backup pages")
        }
        guard let backup = sqlite3_backup_init(destination, "main", connection.handle, "main") else {
            throw failure(sqlite3_errcode(destination), "unable to initialize migration backup")
        }
        let stepResult = sqlite3_backup_step(backup, -1)
        let finishResult = sqlite3_backup_finish(backup)
        guard stepResult == SQLITE_DONE else {
            throw failure(stepResult, "unable to complete migration backup")
        }
        guard finishResult == SQLITE_OK else {
            throw failure(finishResult, "unable to finalize migration backup")
        }

        var serializedSize: sqlite3_int64 = 0
        guard let serialized = sqlite3_serialize(
            destination,
            "main",
            &serializedSize,
            UInt32(SQLITE_SERIALIZE_NOCOPY)
        ), serializedSize > 0,
           serializedSize <= sqlite3_int64(layout.byteCount),
           serializedSize <= sqlite3_int64(maximumBackupBytes),
           let byteCount = Int(exactly: serializedSize) else {
            throw failure(SQLITE_NOMEM, "bounded migration backup is not directly serializable")
        }
        try backupOperation(
            .didSerializeBackup(byteCount: byteCount, usedNoCopy: true)
        )
        var written = 0
        while written < byteCount {
            let result = pwrite(
                descriptor,
                serialized.advanced(by: written),
                byteCount - written,
                off_t(written)
            )
            guard result > 0 else {
                if result < 0, errno == EINTR { continue }
                throw posixFailure("unable to write migration backup")
            }
            written += result
        }
        let closeResult = sqlite3_close(destination)
        destinationOpen = false
        guard closeResult == SQLITE_OK else {
            throw failure(closeResult, "unable to close bounded migration backup image")
        }

        var information = stat()
        guard fstat(descriptor, &information) == 0,
              information.st_mode & S_IFMT == S_IFREG,
              information.st_nlink == 1,
              information.st_size == off_t(byteCount) else {
            throw failure(SQLITE_CANTOPEN, "unsafe migration backup file")
        }
        guard fsync(descriptor) == 0 else { throw posixFailure("unable to sync migration backup") }
        guard fsync(directory) == 0 else { throw posixFailure("unable to sync migration backup directory") }
        completed = true
    }

    private func retainNewestTwoBackups(in directory: Int32) throws {
        let candidates = try listNames(in: directory).compactMap { name -> BackupCandidate? in
            guard DatabaseBackupNaming.isBackupFilename(name) else { return nil }
            let descriptor = openat(
                directory,
                name,
                O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK
            )
            guard descriptor >= 0 else { return nil }
            defer { Darwin.close(descriptor) }
            var information = stat()
            guard fstat(descriptor, &information) == 0,
                  information.st_mode & S_IFMT == S_IFREG,
                  information.st_nlink == 1 else { return nil }
            return BackupCandidate(name: name, information: information)
        }.sorted { lhs, rhs in
            if lhs.information.st_mtimespec.tv_sec != rhs.information.st_mtimespec.tv_sec {
                return lhs.information.st_mtimespec.tv_sec > rhs.information.st_mtimespec.tv_sec
            }
            if lhs.information.st_mtimespec.tv_nsec != rhs.information.st_mtimespec.tv_nsec {
                return lhs.information.st_mtimespec.tv_nsec > rhs.information.st_mtimespec.tv_nsec
            }
            return lhs.name > rhs.name
        }

        var removed = false
        for stale in candidates.dropFirst(2) {
            var current = stat()
            guard fstatat(directory, stale.name, &current, AT_SYMLINK_NOFOLLOW) == 0,
                  current.st_dev == stale.information.st_dev,
                  current.st_ino == stale.information.st_ino,
                  current.st_nlink == 1,
                  current.st_mode & S_IFMT == S_IFREG else { continue }
            guard unlinkat(directory, stale.name, 0) == 0 else {
                throw posixFailure("unable to prune migration backup")
            }
            removed = true
        }
        if removed, fsync(directory) != 0 {
            throw posixFailure("unable to sync migration backup retention")
        }
    }

    private func listNames(in directory: Int32) throws -> [String] {
        let duplicate = dup(directory)
        guard duplicate >= 0,
              lseek(duplicate, 0, SEEK_SET) >= 0,
              let stream = fdopendir(duplicate) else {
            if duplicate >= 0 { Darwin.close(duplicate) }
            throw posixFailure("unable to enumerate migration backups")
        }
        defer { closedir(stream) }
        var names: [String] = []
        while let entry = readdir(stream) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: Int(NAME_MAX) + 1) {
                    String(cString: $0)
                }
            }
            if name != ".", name != ".." { names.append(name) }
        }
        return names
    }

    private func unlinkCreatedFile(_ descriptor: Int32, in directory: Int32, name: String) {
        var descriptorInfo = stat()
        var namedInfo = stat()
        guard fstat(descriptor, &descriptorInfo) == 0,
              fstatat(directory, name, &namedInfo, AT_SYMLINK_NOFOLLOW) == 0,
              descriptorInfo.st_dev == namedInfo.st_dev,
              descriptorInfo.st_ino == namedInfo.st_ino else { return }
        _ = unlinkat(directory, name, 0)
        _ = fsync(directory)
    }

    private func checksum(for sql: String) -> String {
        SHA256.hash(data: Data(sql.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func corrupt(_ message: String) -> SQLiteFailure {
        failure(SQLITE_CORRUPT, message)
    }

    private func failure(_ code: Int32, _ message: String) -> SQLiteFailure {
        SQLiteFailure(code: code, message: message)
    }

    private func posixFailure(_ message: String) -> SQLiteFailure {
        failure(SQLITE_IOERR, "\(message): \(String(cString: strerror(errno)))")
    }

    private func isSinglePathComponent(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains("/")
    }

    private static let schemaMigrationsSQL = """
    CREATE TABLE IF NOT EXISTS schema_migrations(
      version INTEGER PRIMARY KEY,
      name TEXT NOT NULL,
      checksum TEXT NOT NULL,
      applied_at TEXT NOT NULL
    );
    """
}

private struct BackupCandidate {
    let name: String
    let information: stat
}

private struct BackupLayout {
    let pageSize: Int64
    let byteCount: Int
}

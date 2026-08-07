import CSQLite
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
    case willPruneBackup(name: String)
    case didValidateCreatedBackup
    case didSyncBackupDirectoryEntry
    case willQuarantineBackup(name: String)
}

struct DatabaseMigrationMemoryOperations: @unchecked Sendable {
    let allocate: (Int) -> UnsafeMutableRawPointer?
    let deserialize: (
        OpaquePointer,
        UnsafeMutableRawPointer,
        sqlite3_int64,
        sqlite3_int64,
        UInt32
    ) -> Int32
    let release: (UnsafeMutableRawPointer) -> Void

    static let sqlite = DatabaseMigrationMemoryOperations(
        allocate: { sqlite3_malloc64(sqlite3_uint64($0)) },
        deserialize: { database, storage, databaseBytes, capacity, flags in
            sqlite3_deserialize(
                database,
                "main",
                storage,
                databaseBytes,
                capacity,
                flags
            )
        },
        release: sqlite3_free
    )
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
    private let memoryOperations: DatabaseMigrationMemoryOperations

    public init(connection: SQLiteConnection, backupDirectory: URL, migrations: [Migration]) {
        self.connection = connection
        self.backupDirectory = backupDirectory
        self.migrations = migrations
        backupName = DatabaseBackupNaming.canonical
        backupOperation = { _ in }
        maximumBackupBytes = DatabaseRecoveryService.maximumRecoveryImageBytes
        memoryOperations = .sqlite
    }

    init(
        connection: SQLiteConnection,
        backupDirectory: URL,
        migrations: [Migration],
        backupName: @escaping (Int32) -> String,
        backupOperation: @escaping (DatabaseMigrationBackupOperation) throws -> Void = { _ in },
        maximumBackupBytes: Int = DatabaseRecoveryService.maximumRecoveryImageBytes,
        memoryOperations: DatabaseMigrationMemoryOperations = .sqlite
    ) {
        self.connection = connection
        self.backupDirectory = backupDirectory
        self.migrations = migrations
        self.backupName = backupName
        self.backupOperation = backupOperation
        self.maximumBackupBytes = maximumBackupBytes
        self.memoryOperations = memoryOperations
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
            try withBackupDirectory { handles in
                let created = try createBackup(
                    in: handles.directory,
                    version: currentVersion,
                    layout: layout
                )
                var completed = false
                var quarantined: [QuarantinedBackup] = []
                defer {
                    if !completed {
                        restoreQuarantinedBackups(quarantined, in: handles.directory)
                        unlinkCreatedFile(created.descriptor, in: handles.directory, name: created.name)
                    }
                    Darwin.close(created.descriptor)
                }
                quarantined = try retainNewestTwoBackups(
                    in: handles.directory,
                    preserving: created
                )
                let finalIdentity = try DatabaseBackupArtifact.validate(
                    descriptor: created.descriptor,
                    maximumBytes: maximumBackupBytes,
                    migrations: migrations
                )
                guard finalIdentity == created.identity,
                      name(created.name, in: handles.directory, binds: finalIdentity) else {
                    throw failure(SQLITE_CANTOPEN, "migration backup binding changed")
                }
                try apply(pending, from: currentVersion) {
                    try backupOperation(.didValidateCreatedBackup)
                    try ensureCanonicalDirectoryBindings(handles)
                    let commitIdentity = try DatabaseBackupArtifact.validate(
                        descriptor: created.descriptor,
                        maximumBytes: maximumBackupBytes,
                        migrations: migrations
                    )
                    guard commitIdentity == created.identity,
                          name(created.name, in: handles.directory, binds: commitIdentity) else {
                        throw failure(SQLITE_CANTOPEN, "migration backup binding changed")
                    }
                    try ensureCanonicalDirectoryBindings(handles)
                    completed = true
                    try finalizeQuarantinedBackups(quarantined, in: handles.directory)
                }
            }
            return
        }
        try apply(pending, from: currentVersion)
    }

    private func apply(
        _ pending: [Migration],
        from currentVersion: Int32,
        beforeFirstSchemaWrite: () throws -> Void = {}
    ) throws {
        for (index, migration) in pending.enumerated() {
            try connection.transaction {
                if index == pending.startIndex { try beforeFirstSchemaWrite() }
                if currentVersion == 0, migration.version == 1 {
                    try connection.execute(databaseSchemaMigrationsSQL)
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

    private func withBackupDirectory(_ body: (BackupDirectoryHandles) throws -> Void) throws {
        let standardized = backupDirectory.standardizedFileURL
        guard backupDirectory.isFileURL,
              backupDirectory.path == standardized.path,
              isSinglePathComponent(standardized.lastPathComponent) else {
            throw failure(SQLITE_CANTOPEN, "invalid migration backup directory")
        }
        let canonical = canonicalSystemURL(standardized)
        let parentURL = canonical.deletingLastPathComponent()
        let parent = try openDirectoryPathNoFollow(parentURL.path)
        defer { Darwin.close(parent) }

        let name = canonical.lastPathComponent
        let createResult = mkdirat(parent, name, S_IRWXU)
        if createResult != 0, errno != EEXIST {
            throw posixFailure("unable to create migration backup directory")
        }
        try syncDirectory(parent, failureMessage: "unable to sync migration backup parent")
        try backupOperation(.didSyncBackupDirectoryEntry)
        let directory = openat(
            parent,
            name,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        )
        guard directory >= 0 else { throw posixFailure("unable to open migration backup directory") }
        defer { Darwin.close(directory) }
        guard directoriesMatch(parent, parent), directoryIsLinked(directory),
              directoryName(name, in: parent, binds: directory) else {
            throw failure(SQLITE_CANTOPEN, "unsafe migration backup directory")
        }
        try backupOperation(.didOpenBackupDirectory)
        try body(BackupDirectoryHandles(
            parentURL: parentURL,
            name: name,
            parent: parent,
            directory: directory
        ))
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
    ) throws -> CreatedBackup {
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
        var returned = false
        defer {
            if !returned {
                unlinkCreatedFile(descriptor, in: directory, name: name)
                Darwin.close(descriptor)
            }
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
        guard let storage = memoryOperations.allocate(layout.byteCount) else {
            throw failure(SQLITE_NOMEM, "unable to allocate bounded migration backup image")
        }
        var ownershipTransferred = false
        defer {
            if !ownershipTransferred { memoryOperations.release(storage) }
        }
        ownershipTransferred = true
        let deserializeResult = memoryOperations.deserialize(
            destination,
            storage,
            0,
            sqlite3_int64(layout.byteCount),
            UInt32(SQLITE_DESERIALIZE_FREEONCLOSE)
        )
        guard deserializeResult == SQLITE_OK else {
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
        let identity = try DatabaseBackupArtifact.validate(
            descriptor: descriptor,
            maximumBytes: maximumBackupBytes,
            migrations: migrations
        )
        guard self.name(name, in: directory, binds: identity) else {
            throw failure(SQLITE_CANTOPEN, "migration backup binding changed")
        }
        returned = true
        return CreatedBackup(name: name, descriptor: descriptor, identity: identity)
    }

    private func retainNewestTwoBackups(
        in directory: Int32,
        preserving created: CreatedBackup
    ) throws -> [QuarantinedBackup] {
        let candidates = try listNames(in: directory).compactMap { name -> BackupCandidate? in
            guard DatabaseBackupNaming.isBackupFilename(name) else { return nil }
            let descriptor = openat(
                directory,
                name,
                O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK
            )
            guard descriptor >= 0 else { return nil }
            do {
                let identity = try DatabaseBackupArtifact.validate(
                    descriptor: descriptor,
                    maximumBytes: maximumBackupBytes,
                    migrations: migrations
                )
                return BackupCandidate(
                    name: name,
                    descriptor: descriptor,
                    identity: identity,
                    isCreated: name == created.name && identity == created.identity
                )
            } catch {
                Darwin.close(descriptor)
                return nil
            }
        }.sorted { lhs, rhs in
            if lhs.isCreated != rhs.isCreated { return lhs.isCreated }
            if lhs.identity.modificationSeconds != rhs.identity.modificationSeconds {
                return lhs.identity.modificationSeconds > rhs.identity.modificationSeconds
            }
            if lhs.identity.modificationNanoseconds != rhs.identity.modificationNanoseconds {
                return lhs.identity.modificationNanoseconds > rhs.identity.modificationNanoseconds
            }
            return lhs.name > rhs.name
        }
        defer { candidates.forEach { Darwin.close($0.descriptor) } }

        var quarantined: [QuarantinedBackup] = []
        do {
            for stale in candidates.dropFirst(2) {
                try backupOperation(.willPruneBackup(name: stale.name))
                guard let currentIdentity = try? DatabaseBackupArtifact.validate(
                    descriptor: stale.descriptor,
                    maximumBytes: maximumBackupBytes,
                    migrations: migrations
                ), currentIdentity == stale.identity else { continue }
                try backupOperation(.willQuarantineBackup(name: stale.name))
                if let candidate = try quarantineCandidate(stale, in: directory) {
                    quarantined.append(candidate)
                }
            }
            if !quarantined.isEmpty {
                try syncDirectory(
                    directory,
                    failureMessage: "unable to sync migration backup retention"
                )
            }
            return quarantined
        } catch {
            restoreQuarantinedBackups(quarantined, in: directory)
            throw error
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
        guard fstat(descriptor, &descriptorInfo) == 0 else { return }
        let candidates = ([name] + ((try? listNames(in: directory)) ?? [])).uniqued()
        for candidate in candidates {
            var namedInfo = stat()
            guard fstatat(directory, candidate, &namedInfo, AT_SYMLINK_NOFOLLOW) == 0,
                  descriptorInfo.st_dev == namedInfo.st_dev,
                  descriptorInfo.st_ino == namedInfo.st_ino else { continue }
            let quarantine = ".tokenboard-cleanup-\(UUID().uuidString.lowercased())"
            guard renameatx_np(
                directory,
                candidate,
                directory,
                quarantine,
                UInt32(RENAME_EXCL)
            ) == 0 else { continue }
            var quarantinedInfo = stat()
            var currentDescriptorInfo = stat()
            guard fstat(descriptor, &currentDescriptorInfo) == 0,
                  fstatat(directory, quarantine, &quarantinedInfo, AT_SYMLINK_NOFOLLOW) == 0,
                  sameRegularFile(currentDescriptorInfo, quarantinedInfo) else {
                restoreQuarantine(quarantine, to: candidate, in: directory)
                continue
            }
            if unlinkat(directory, quarantine, 0) == 0 { _ = fsync(directory) }
            return
        }
    }

    private func quarantineCandidate(
        _ candidate: BackupCandidate,
        in directory: Int32
    ) throws -> QuarantinedBackup? {
        let quarantine = ".tokenboard-prune-\(UUID().uuidString.lowercased())"
        guard renameatx_np(
            directory,
            candidate.name,
            directory,
            quarantine,
            UInt32(RENAME_EXCL)
        ) == 0 else {
            if errno == ENOENT || errno == EEXIST { return nil }
            throw posixFailure("unable to quarantine migration backup")
        }
        var quarantinedInfo = stat()
        guard let currentIdentity = try? DatabaseBackupArtifact.validate(
            descriptor: candidate.descriptor,
            maximumBytes: maximumBackupBytes,
            migrations: migrations
        ), currentIdentity == candidate.identity,
        fstatat(directory, quarantine, &quarantinedInfo, AT_SYMLINK_NOFOLLOW) == 0,
        candidate.identity.binds(quarantinedInfo) else {
            restoreQuarantine(quarantine, to: candidate.name, in: directory)
            return nil
        }
        return QuarantinedBackup(originalName: candidate.name, quarantineName: quarantine)
    }

    private func finalizeQuarantinedBackups(
        _ quarantined: [QuarantinedBackup],
        in directory: Int32
    ) throws {
        for (index, candidate) in quarantined.enumerated() {
            guard unlinkat(directory, candidate.quarantineName, 0) == 0 else {
                restoreQuarantinedBackups(Array(quarantined[index...]), in: directory)
                throw posixFailure("unable to prune migration backup")
            }
        }
        if !quarantined.isEmpty {
            try syncDirectory(directory, failureMessage: "unable to sync migration backup retention")
        }
    }

    private func restoreQuarantinedBackups(
        _ quarantined: [QuarantinedBackup],
        in directory: Int32
    ) {
        for candidate in quarantined {
            restoreQuarantine(
                candidate.quarantineName,
                to: candidate.originalName,
                in: directory
            )
        }
    }

    private func restoreQuarantine(_ quarantine: String, to name: String, in directory: Int32) {
        _ = renameatx_np(
            directory,
            quarantine,
            directory,
            name,
            UInt32(RENAME_EXCL)
        )
        _ = fsync(directory)
    }

    private func sameRegularFile(_ lhs: stat, _ rhs: stat) -> Bool {
        lhs.st_mode & S_IFMT == S_IFREG
            && rhs.st_mode & S_IFMT == S_IFREG
            && lhs.st_nlink == 1
            && rhs.st_nlink == 1
            && lhs.st_dev == rhs.st_dev
            && lhs.st_ino == rhs.st_ino
    }

    private func syncDirectory(_ descriptor: Int32, failureMessage: String) throws {
        while fsync(descriptor) != 0 {
            if errno == EINTR { continue }
            throw posixFailure(failureMessage)
        }
    }

    private func checksum(for sql: String) -> String {
        databaseMigrationChecksum(sql)
    }

    private func ensureCanonicalDirectoryBindings(_ handles: BackupDirectoryHandles) throws {
        let currentParent = try openDirectoryPathNoFollow(handles.parentURL.path)
        defer { Darwin.close(currentParent) }
        guard directoriesMatch(handles.parent, currentParent),
              directoryName(handles.name, in: currentParent, binds: handles.directory) else {
            throw failure(SQLITE_CANTOPEN, "migration backup namespace changed")
        }
    }

    private func openDirectoryPathNoFollow(_ path: String) throws -> Int32 {
        guard path.hasPrefix("/") else {
            throw failure(SQLITE_CANTOPEN, "invalid migration backup parent")
        }
        var descriptor = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard descriptor >= 0 else { throw posixFailure("unable to open migration backup parent") }
        do {
            for component in path.split(separator: "/").map(String.init) {
                guard isSinglePathComponent(component) else {
                    throw failure(SQLITE_CANTOPEN, "invalid migration backup parent")
                }
                let next = openat(
                    descriptor,
                    component,
                    O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
                )
                guard next >= 0 else { throw posixFailure("unable to open migration backup parent") }
                Darwin.close(descriptor)
                descriptor = next
            }
            return descriptor
        } catch {
            Darwin.close(descriptor)
            throw error
        }
    }

    private func directoriesMatch(_ lhs: Int32, _ rhs: Int32) -> Bool {
        var left = stat()
        var right = stat()
        return fstat(lhs, &left) == 0
            && fstat(rhs, &right) == 0
            && left.st_mode & S_IFMT == S_IFDIR
            && right.st_mode & S_IFMT == S_IFDIR
            && left.st_nlink > 0
            && right.st_nlink > 0
            && left.st_dev == right.st_dev
            && left.st_ino == right.st_ino
            && left.st_nlink == right.st_nlink
    }

    private func directoryIsLinked(_ descriptor: Int32) -> Bool {
        var information = stat()
        return fstat(descriptor, &information) == 0
            && information.st_mode & S_IFMT == S_IFDIR
            && information.st_nlink > 0
    }

    private func directoryName(_ name: String, in parent: Int32, binds descriptor: Int32) -> Bool {
        var expected = stat()
        var actual = stat()
        return fstat(descriptor, &expected) == 0
            && fstatat(parent, name, &actual, AT_SYMLINK_NOFOLLOW) == 0
            && expected.st_mode & S_IFMT == S_IFDIR
            && actual.st_mode & S_IFMT == S_IFDIR
            && expected.st_nlink > 0
            && actual.st_nlink > 0
            && expected.st_dev == actual.st_dev
            && expected.st_ino == actual.st_ino
            && expected.st_nlink == actual.st_nlink
    }

    private func name(
        _ name: String,
        in directory: Int32,
        binds identity: DatabaseBackupArtifactIdentity
    ) -> Bool {
        var information = stat()
        return fstatat(directory, name, &information, AT_SYMLINK_NOFOLLOW) == 0
            && identity.binds(information)
    }

    private func canonicalSystemURL(_ url: URL) -> URL {
        let path = url.path
        if path == "/var" || path.hasPrefix("/var/")
            || path == "/tmp" || path.hasPrefix("/tmp/") {
            return URL(fileURLWithPath: "/private" + path)
        }
        return url
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

}

let databaseSchemaMigrationsSQL = """
CREATE TABLE IF NOT EXISTS schema_migrations(
  version INTEGER PRIMARY KEY,
  name TEXT NOT NULL,
  checksum TEXT NOT NULL,
  applied_at TEXT NOT NULL
);
"""

private final class BackupCandidate {
    let name: String
    let descriptor: Int32
    let identity: DatabaseBackupArtifactIdentity
    let isCreated: Bool
    init(
        name: String,
        descriptor: Int32,
        identity: DatabaseBackupArtifactIdentity,
        isCreated: Bool
    ) {
        self.name = name
        self.descriptor = descriptor
        self.identity = identity
        self.isCreated = isCreated
    }
}

private struct BackupLayout {
    let pageSize: Int64
    let byteCount: Int
}

private struct BackupDirectoryHandles {
    let parentURL: URL
    let name: String
    let parent: Int32
    let directory: Int32
}

private struct CreatedBackup {
    let name: String
    let descriptor: Int32
    let identity: DatabaseBackupArtifactIdentity
}

private struct QuarantinedBackup {
    let originalName: String
    let quarantineName: String
}

private extension Array where Element: Hashable {
    func uniqued() -> [Element] {
        var seen: Set<Element> = []
        return filter { seen.insert($0).inserted }
    }
}
